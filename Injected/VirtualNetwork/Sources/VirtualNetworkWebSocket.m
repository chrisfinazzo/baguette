// VirtualNetworkWebSocket — conditions `URLSessionWebSocketTask`.
//
// WebSockets are part of the URL Loading System but do **not** go through
// `NSURLProtocol`: once the socket is open, messages bypass the protocol
// machinery entirely. So they need their own hooks, on the two methods every
// client funnels through — `sendMessage:completionHandler:` outbound and
// `receiveMessageWithCompletionHandler:` inbound.
//
// This only reaches Apple's WebSocket API, which is a real limit rather than
// a detail: `URLSessionWebSocketTask` arrived in iOS 13 and plenty of
// realtime SDKs ship their own transport. Measured against an app using
// Ably's `ably-cocoa`, which vendors SocketRocket on top of `CFStream`, the
// hooks installed and not one of them fired. Starscream is the same. The
// `conditioning websocket …` log lines are how you tell "installed" from
// "actually being used".
//
// What is applied, and what is not:
//
//   latency  — both directions, before the message is handed on.
//   loss     — outbound: the send fails. Inbound: the message is *dropped*
//              and the receive re-issued, because losing one message is not
//              the same as tearing down the socket.
//   offline  — both directions fail with NSURLErrorNotConnectedToInternet.
//   bandwidth — NOT applied. See the note on pacing below.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import "VirtualNetworkCondition.h"

typedef void (^VNSendCompletion)(NSError *error);
typedef void (^VNReceiveCompletion)(NSURLSessionWebSocketMessage *message, NSError *error);

/// One entry per class we replaced a method on.
///
/// `NSURLSessionWebSocketTask` is the public face; the object an app actually
/// holds is a private concrete subclass that implements these methods itself.
/// Replacing the public class's IMP therefore changes nothing — measured, and
/// it is why the first version of these hooks installed cleanly and never
/// fired. So every class in the hierarchy that *directly* implements them is
/// hooked, and each keeps its own original to chain to.
typedef struct {
    __unsafe_unretained Class cls;
    void (*send)(id, SEL, NSURLSessionWebSocketMessage *, VNSendCompletion);
    void (*receive)(id, SEL, VNReceiveCompletion);
} VNHookedClass;

/// Generous: in practice this is one or two classes.
///
/// Guarded because task creation happens on whatever thread the app is on,
/// and two threads racing here is not merely a torn table: the loser can
/// read our *replacement* IMP as the "original" it chains to, and the hook
/// then calls itself forever.
static VNHookedClass gHooked[8];
static NSUInteger gHookedCount;
static os_unfair_lock gHookLock = OS_UNFAIR_LOCK_INIT;

/// The original implementations for `self`, found by walking its class chain
/// — the instance may be a subclass of whichever class we replaced.
/// Copies the entry out under the lock rather than returning a pointer into
/// the table, so a concurrent append can't move the ground under a caller.
static BOOL VNOriginalsFor(id object, VNHookedClass *out) {
    BOOL found = NO;
    os_unfair_lock_lock(&gHookLock);
    for (Class cls = object_getClass(object); cls && !found; cls = class_getSuperclass(cls)) {
        for (NSUInteger i = 0; i < gHookedCount; i++) {
            if (gHooked[i].cls == cls) { *out = gHooked[i]; found = YES; break; }
        }
    }
    os_unfair_lock_unlock(&gHookLock);
    return found;
}

/// How long an offline failure is held before being reported.
///
/// Clients almost always re-arm the receive as soon as one completes, so
/// failing instantly turns an offline socket into a busy loop that pins a
/// core inside the app under test. A short delay keeps the behaviour
/// ("nothing is arriving, and it says no connection") without the spin.
static const double kOfflineBackoffSeconds = 0.25;

static NSError *VNError(NSInteger code) {
    return [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil];
}

static BOOL VNRollsLost(VNCondition condition) {
    return condition.lossPercent > 0
        && arc4random_uniform(100) < (uint32_t)condition.lossPercent;
}

static void VNAfter(double seconds, dispatch_block_t block) {
    if (seconds <= 0) { block(); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), block);
}

#pragma mark - Outbound

static void VNSendMessage(id self, SEL _cmd, NSURLSessionWebSocketMessage *message,
                          VNSendCompletion completion) {
    VNHookedClass originals;
    if (!VNOriginalsFor(self, &originals)) return;
    VNCondition condition = VNConditionCurrent();
    if (!condition.conditioning) {
        originals.send(self, _cmd, message, completion);
        return;
    }
    if (condition.offline) {
        VNLogThrottled("ws-offline", @"[VirtualNetwork] websocket send refused — offline");
        if (completion) completion(VNError(NSURLErrorNotConnectedToInternet));
        return;
    }
    if (VNRollsLost(condition)) {
        VNLogThrottled("ws-loss", @"[VirtualNetwork] websocket send dropped — loss");
        if (completion) completion(VNError(NSURLErrorNetworkConnectionLost));
        return;
    }
    VNLogThrottled("ws-send", @"[VirtualNetwork] conditioning websocket send (%.0f ms)",
                   condition.latencyMs);
    VNAfter(condition.latencyMs / 1000.0, ^{
        originals.send(self, _cmd, message, completion);
    });
}

#pragma mark - Inbound

/// Re-issues a receive after an inbound message was dropped.
///
/// Declared separately so the drop path can recurse without the block
/// capturing itself — losing a message must leave the client's single
/// outstanding receive intact, or the socket goes quiet forever after the
/// first drop, which is a disconnection rather than packet loss.
static void VNReceiveMessage(id self, SEL _cmd, VNReceiveCompletion completion);

static void VNDeliver(id self, SEL _cmd, NSURLSessionWebSocketMessage *message,
                      NSError *error, VNReceiveCompletion completion) {
    VNCondition condition = VNConditionCurrent();

    // An upstream error, or nothing being conditioned any more: hand it over
    // untouched. Delaying a real disconnection helps nobody.
    if (error || !condition.conditioning) {
        completion(message, error);
        return;
    }
    if (condition.offline) {
        VNLogThrottled("ws-offline-in",
                       @"[VirtualNetwork] websocket receive refused — offline");
        VNAfter(kOfflineBackoffSeconds, ^{
            completion(nil, VNError(NSURLErrorNotConnectedToInternet));
        });
        return;
    }
    if (VNRollsLost(condition)) {
        // Swallow it and listen again. Completing with an error here would
        // end the client's receive loop — that is a dropped *connection*,
        // not a dropped message, and apps react to the two very differently.
        VNLogThrottled("ws-loss-in", @"[VirtualNetwork] websocket message dropped — loss");
        VNReceiveMessage(self, _cmd, completion);
        return;
    }
    VNAfter(condition.latencyMs / 1000.0, ^{ completion(message, error); });
}

static void VNReceiveMessage(id self, SEL _cmd, VNReceiveCompletion completion) {
    VNHookedClass originals;
    if (!VNOriginalsFor(self, &originals)) return;
    VNCondition condition = VNConditionCurrent();
    if (!condition.conditioning) {
        originals.receive(self, _cmd, completion);
        return;
    }
    originals.receive(self, _cmd, ^(NSURLSessionWebSocketMessage *message, NSError *error) {
        VNDeliver(self, _cmd, message, error, completion);
    });
}

#pragma mark - Install

/// Hooks `URLSessionWebSocketTask`. Returns NO when the class or either
/// method is missing, so the banner can say the surface is unhooked rather
/// than letting an app believe its realtime layer is being conditioned.
///
/// **Bandwidth is deliberately not applied.** Pacing bytes is meaningful for
/// a response body an app streams; a WebSocket message is delivered whole and
/// an app cannot observe a partial one, so the only honest way to express a
/// bandwidth cap would be to delay whole messages by their size — which is
/// latency wearing a different name. Latency, loss and offline say what they
/// mean here; bandwidth would not.

/// Replaces both methods on `cls`, but only if `cls` implements them itself —
/// `class_getInstanceMethod` happily returns an inherited method, and
/// replacing that would rewrite the superclass's implementation from under
/// every other subclass.
static BOOL VNHookClass(Class cls) {
    SEL sendSel = @selector(sendMessage:completionHandler:);
    SEL receiveSel = @selector(receiveMessageWithCompletionHandler:);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL ownsSend = NO, ownsReceive = NO;
    for (unsigned int i = 0; i < count; i++) {
        SEL name = method_getName(methods[i]);
        if (name == sendSel) ownsSend = YES;
        if (name == receiveSel) ownsReceive = YES;
    }
    free(methods);
    if (!ownsSend || !ownsReceive) return NO;

    os_unfair_lock_lock(&gHookLock);
    // Re-check under the lock: another thread may have hooked this class
    // between our caller looking and us arriving.
    for (NSUInteger i = 0; i < gHookedCount; i++) {
        if (gHooked[i].cls == cls) {
            os_unfair_lock_unlock(&gHookLock);
            return NO;
        }
    }
    if (gHookedCount >= sizeof(gHooked) / sizeof(gHooked[0])) {
        os_unfair_lock_unlock(&gHookLock);
        return NO;
    }

    Method send = class_getInstanceMethod(cls, sendSel);
    Method receive = class_getInstanceMethod(cls, receiveSel);
    gHooked[gHookedCount] = (VNHookedClass){
        .cls = cls,
        .send = (void *)method_getImplementation(send),
        .receive = (void *)method_getImplementation(receive),
    };
    gHookedCount++;
    method_setImplementation(send, (IMP)VNSendMessage);
    method_setImplementation(receive, (IMP)VNReceiveMessage);
    os_unfair_lock_unlock(&gHookLock);
    return YES;
}

/// Hooks whatever class `task` actually is, the first time we see one.
///
/// This is why task creation is intercepted at all. Sweeping the class list
/// at load finds only `NSURLSessionWebSocketTask`; the concrete subclass that
/// overrides these methods is registered lazily, the first time an app asks
/// for a socket — so a load-time sweep hooks the public class, reports
/// success, and never fires. Measured, twice.
static void VNAdoptTaskClass(id task) {
    if (!task) return;
    // `VNHookClass` takes the lock and re-checks, so the whole
    // already-hooked?/hook sequence is atomic. Doing the check out here
    // instead would let two threads both decide to hook, and the loser would
    // record our replacement IMP as the original it chains to — a hook that
    // calls itself forever.
    Class cls = object_getClass(task);
    if (VNHookClass(cls)) {
        VNLog(@"[VirtualNetwork] websocket hooks on %@", NSStringFromClass(cls));
    }
}

static id (*gOriginalTaskWithURL)(id, SEL, NSURL *);
static id (*gOriginalTaskWithURLProtocols)(id, SEL, NSURL *, NSArray *);
static id (*gOriginalTaskWithRequest)(id, SEL, NSURLRequest *);

static id VNTaskWithURL(id self, SEL _cmd, NSURL *url) {
    id task = gOriginalTaskWithURL(self, _cmd, url);
    VNAdoptTaskClass(task);
    return task;
}
static id VNTaskWithURLProtocols(id self, SEL _cmd, NSURL *url, NSArray *protocols) {
    id task = gOriginalTaskWithURLProtocols(self, _cmd, url, protocols);
    VNAdoptTaskClass(task);
    return task;
}
static id VNTaskWithRequest(id self, SEL _cmd, NSURLRequest *request) {
    id task = gOriginalTaskWithRequest(self, _cmd, request);
    VNAdoptTaskClass(task);
    return task;
}

BOOL VNInstallWebSocketHooks(void) {
    Class session = objc_getClass("NSURLSession");
    if (!session) return NO;

    Method withURL = class_getInstanceMethod(session, @selector(webSocketTaskWithURL:));
    Method withProtocols = class_getInstanceMethod(
        session, @selector(webSocketTaskWithURL:protocols:));
    Method withRequest = class_getInstanceMethod(
        session, @selector(webSocketTaskWithRequest:));
    if (!withURL && !withProtocols && !withRequest) return NO;

    if (withURL) {
        gOriginalTaskWithURL = (void *)method_getImplementation(withURL);
        method_setImplementation(withURL, (IMP)VNTaskWithURL);
    }
    if (withProtocols) {
        gOriginalTaskWithURLProtocols = (void *)method_getImplementation(withProtocols);
        method_setImplementation(withProtocols, (IMP)VNTaskWithURLProtocols);
    }
    if (withRequest) {
        gOriginalTaskWithRequest = (void *)method_getImplementation(withRequest);
        method_setImplementation(withRequest, (IMP)VNTaskWithRequest);
    }

    // The public class too, in case a runtime makes it concrete. Harmless
    // when it isn't — the per-class table means the subclass hook chains to
    // its own original either way.
    Class base = objc_getClass("NSURLSessionWebSocketTask");
    if (base && VNHookClass(base)) {
        VNLog(@"[VirtualNetwork] websocket hooks on %@", NSStringFromClass(base));
    }
    return YES;
}
