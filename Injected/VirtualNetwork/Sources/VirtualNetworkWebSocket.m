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
#import "VirtualNetworkCondition.h"

typedef void (^VNSendCompletion)(NSError *error);
typedef void (^VNReceiveCompletion)(NSURLSessionWebSocketMessage *message, NSError *error);

static void (*gOriginalSend)(id, SEL, NSURLSessionWebSocketMessage *, VNSendCompletion);
static void (*gOriginalReceive)(id, SEL, VNReceiveCompletion);

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
    VNCondition condition = VNConditionCurrent();
    if (!condition.conditioning) {
        gOriginalSend(self, _cmd, message, completion);
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
        gOriginalSend(self, _cmd, message, completion);
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
    VNCondition condition = VNConditionCurrent();
    if (!condition.conditioning) {
        gOriginalReceive(self, _cmd, completion);
        return;
    }
    gOriginalReceive(self, _cmd, ^(NSURLSessionWebSocketMessage *message, NSError *error) {
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
BOOL VNInstallWebSocketHooks(void) {
    Class cls = objc_getClass("NSURLSessionWebSocketTask");
    if (!cls) return NO;

    Method send = class_getInstanceMethod(cls, @selector(sendMessage:completionHandler:));
    Method receive = class_getInstanceMethod(
        cls, @selector(receiveMessageWithCompletionHandler:));
    if (!send || !receive) return NO;

    gOriginalSend = (void *)method_getImplementation(send);
    gOriginalReceive = (void *)method_getImplementation(receive);
    method_setImplementation(send, (IMP)VNSendMessage);
    method_setImplementation(receive, (IMP)VNReceiveMessage);
    return YES;
}
