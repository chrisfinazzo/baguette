// VirtualNetworkProtocol — the NSURLProtocol that applies baguette's
// published condition to an app's own requests.

#import <Foundation/Foundation.h>

@interface VNProtocol : NSURLProtocol
@end

/// The shared session the protocol re-issues through, built from a **default**
/// configuration with `VNProtocol` stripped out of `protocolClasses`.
///
/// Shared rather than one-per-request so connections are reused. A fresh
/// session per request would mean a fresh TLS handshake per request, which
/// in a tool whose entire job is to add a measured amount of latency would
/// quietly add an unmeasured amount more.
NSURLSession *VNSharedSession(void);
