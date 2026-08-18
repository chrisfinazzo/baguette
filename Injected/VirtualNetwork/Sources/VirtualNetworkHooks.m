// VirtualNetworkHooks — what makes an app's own requests reach `VNProtocol`.
//
// Two mechanisms, and the second is the load-bearing one. Measured against a
// real React Native app before any of this was written:
//
//   +[NSURLProtocol registerClass:]  reaches NSURLConnection and
//       NSURLSession.shared — which in an RN app is the Metro dev-server
//       ping and very little else.
//
//   The configuration-getter swizzle reaches everything that matters: RN's
//       `fetch` (RCTHTTPRequestHandler builds its own session from
//       +defaultSessionConfiguration), image loading, MapLibre's tile
//       requests, and REST clients generally.
//
// A 100-second run with registration alone, against a fully launched and
// online app, intercepted **zero** app requests. Both are installed; only
// one of them is why this feature works.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "VirtualNetworkCondition.h"
#import "VirtualNetworkProtocol.h"

/// Defined in VirtualNetworkWebSocket.m — WebSockets bypass NSURLProtocol
/// once open, so they need hooks of their own.
extern BOOL VNInstallWebSocketHooks(void);

static IMP gOriginalDefault;
static IMP gOriginalEphemeral;

/// Puts `VNProtocol` at the front of a configuration's `protocolClasses`.
/// First, so it is consulted before the built-in HTTP protocol that would
/// otherwise serve the request.
static NSURLSessionConfiguration *VNInject(NSURLSessionConfiguration *config) {
    if (!config) return config;
    NSMutableArray *classes = [config.protocolClasses mutableCopy] ?: NSMutableArray.array;
    if (![classes containsObject:VNProtocol.class]) {
        [classes insertObject:VNProtocol.class atIndex:0];
        config.protocolClasses = classes;
    }
    return config;
}

static id VNDefaultConfiguration(id self, SEL _cmd) {
    return VNInject(((id (*)(id, SEL))gOriginalDefault)(self, _cmd));
}

static id VNEphemeralConfiguration(id self, SEL _cmd) {
    return VNInject(((id (*)(id, SEL))gOriginalEphemeral)(self, _cmd));
}

/// Installs the swizzle and then **verifies it took**, by asking for a
/// configuration and checking our class actually came back in its
/// `protocolClasses`. Replacing an implementation always "succeeds"; whether
/// the returned object still honours a mutated `protocolClasses` is a
/// property of an implementation detail we do not own.
static BOOL VNInstallConfigurationSwizzle(void) {
    Class cls = objc_getClass("NSURLSessionConfiguration");
    if (!cls) return NO;

    Method def = class_getClassMethod(cls, @selector(defaultSessionConfiguration));
    Method eph = class_getClassMethod(cls, @selector(ephemeralSessionConfiguration));
    if (!def) return NO;

    gOriginalDefault = method_getImplementation(def);
    method_setImplementation(def, (IMP)VNDefaultConfiguration);
    if (eph) {
        gOriginalEphemeral = method_getImplementation(eph);
        method_setImplementation(eph, (IMP)VNEphemeralConfiguration);
    }

    BOOL verified = [NSURLSessionConfiguration.defaultSessionConfiguration
                         .protocolClasses containsObject:VNProtocol.class];
    if (!verified) {
        // Put it back. A half-installed swizzle is worse than none: it
        // costs every session an allocation and buys nothing.
        method_setImplementation(def, gOriginalDefault);
        if (eph) method_setImplementation(eph, gOriginalEphemeral);
    }
    return verified;
}

__attribute__((constructor)) static void VirtualNetworkInit(void) {
    BOOL registered = [NSURLProtocol registerClass:VNProtocol.class];
    BOOL swizzled = VNInstallConfigurationSwizzle();

    // Nothing works: unregister and get out of the way. An app is better
    // off with real networking than with networking this dylib has half
    // taken over — and a conditioning tool that silently conditions nothing
    // is worse than one that says so, because the whole point is measuring
    // against a network you believe in.
    if (!registered && !swizzled) {
        [NSURLProtocol unregisterClass:VNProtocol.class];
        VNLog(@"[VirtualNetwork] could not install on any path — leaving networking "
              @"untouched. Neither +registerClass: nor the URLSessionConfiguration "
              @"swizzle took, so requests are NOT being conditioned.");
        return;
    }

    if (!swizzled) {
        // Worth shouting about rather than logging as a detail: without the
        // swizzle this reaches almost nothing an app actually does.
        VNLog(@"[VirtualNetwork] the URLSessionConfiguration swizzle did not take. "
              @"Only NSURLConnection and NSURLSession.shared traffic will be "
              @"conditioned — an app's own requests almost certainly will not.");
    }

    BOOL websockets = VNInstallWebSocketHooks();
    if (!websockets) {
        VNLog(@"[VirtualNetwork] websocket hooks did not install — an app whose realtime "
              @"layer is a WebSocket will keep working normally under any condition, "
              @"including offline.");
    }

    VNCondition condition = VNConditionCurrent();
    VNLog(@"[VirtualNetwork] installed (registerClass=%d configSwizzle=%d websockets=%d) — %@",
          registered, swizzled, websockets,
          condition.conditioning ? @"a condition is armed" : @"nothing is being conditioned");
}
