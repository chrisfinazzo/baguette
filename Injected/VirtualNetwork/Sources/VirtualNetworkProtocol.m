#import "VirtualNetworkProtocol.h"
#import "VirtualNetworkCondition.h"
#import <os/lock.h>

/// Marks a request we have already taken once, so the re-issued copy isn't
/// intercepted again.
///
/// This is load-bearing, not defensive. The configuration-getter swizzle
/// puts `VNProtocol` into the `protocolClasses` of every session built from
/// a default or ephemeral configuration — including the one below — so
/// without the marker the re-issued request is taken again, and again.
/// Measured during the spike: the inner request really does re-enter.
static NSString *const kVNHandled = @"BaguetteNetworkHandled";

/// Backlog above which the upstream task is suspended, and the level it has
/// to drain to before it resumes.
///
/// Pacing means the app is being handed bytes more slowly than the network
/// delivers them, so the difference has to sit somewhere. Without a ceiling
/// that somewhere is unbounded memory — a 23 MB JavaScript bundle over a
/// 240 kbps link would hold the whole thing. Suspending a data task is
/// best-effort flow control rather than a guarantee, so the worst case is
/// still just buffering; the common case stays bounded.
static const NSUInteger kHighWaterBytes = 4 * 1024 * 1024;
static const NSUInteger kLowWaterBytes = 1 * 1024 * 1024;

/// Whether `request` is a WebSocket upgrade rather than an ordinary fetch.
///
/// Checked by header because the scheme is no help: `wss:` has already been
/// rewritten to `https:` by the time a URLProtocol is consulted. `Upgrade`
/// is the header the RFC requires and the one URLSession sets; the
/// `Sec-WebSocket-*` pair is belt and braces in case a future runtime
/// populates them at a different point in the chain.
static BOOL VNIsWebSocketUpgrade(NSURLRequest *request) {
    NSString *upgrade = [request valueForHTTPHeaderField:@"Upgrade"];
    if (upgrade.length && [upgrade caseInsensitiveCompare:@"websocket"] == NSOrderedSame) {
        return YES;
    }
    return [request valueForHTTPHeaderField:@"Sec-WebSocket-Key"].length > 0
        || [request valueForHTTPHeaderField:@"Sec-WebSocket-Version"].length > 0;
}

#pragma mark - Shared session

/// The upstream callbacks, declared ahead of the delegate that calls them.
@interface VNProtocol ()
- (void)vn_didReceiveResponse:(NSURLResponse *)response;
- (void)vn_didReceiveData:(NSData *)data;
- (void)vn_didCompleteWithError:(NSError *)error;
@end

/// Routes delegate callbacks back to the protocol instance that made the
/// request. One session serves every request, so task identifiers are
/// unique within it and make a sufficient key.
@interface VNSessionDelegate : NSObject <NSURLSessionDataDelegate>
@end

@implementation VNSessionDelegate {
    NSMutableDictionary<NSNumber *, VNProtocol *> *_owners;
    os_unfair_lock _lock;
}

+ (instancetype)shared {
    static VNSessionDelegate *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [VNSessionDelegate new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _owners = [NSMutableDictionary dictionary];
        _lock = OS_UNFAIR_LOCK_INIT;
    }
    return self;
}

- (void)adopt:(VNProtocol *)owner forTask:(NSURLSessionTask *)task {
    os_unfair_lock_lock(&_lock);
    _owners[@(task.taskIdentifier)] = owner;
    os_unfair_lock_unlock(&_lock);
}

- (VNProtocol *)ownerOf:(NSURLSessionTask *)task {
    os_unfair_lock_lock(&_lock);
    VNProtocol *owner = _owners[@(task.taskIdentifier)];
    os_unfair_lock_unlock(&_lock);
    return owner;
}

- (void)forget:(NSURLSessionTask *)task {
    os_unfair_lock_lock(&_lock);
    [_owners removeObjectForKey:@(task.taskIdentifier)];
    os_unfair_lock_unlock(&_lock);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    [[self ownerOf:task] vn_didReceiveResponse:response];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    [[self ownerOf:task] vn_didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    VNProtocol *owner = [self ownerOf:task];
    [self forget:task];
    [owner vn_didCompleteWithError:error];
}

@end

NSURLSession *VNSharedSession(void) {
    static NSURLSession *session;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // A *default* configuration, not an ephemeral one: it shares the
        // process's cookie storage and URL cache, which is what the app's
        // own request would have used. An ephemeral session would silently
        // drop cookies and break any app that authenticates with them.
        NSURLSessionConfiguration *config =
            NSURLSessionConfiguration.defaultSessionConfiguration;
        NSMutableArray *classes = [config.protocolClasses mutableCopy] ?: NSMutableArray.array;
        [classes removeObject:VNProtocol.class];
        config.protocolClasses = classes;
        session = [NSURLSession sessionWithConfiguration:config
                                                delegate:VNSessionDelegate.shared
                                           delegateQueue:nil];
    });
    return session;
}

#pragma mark - The protocol

@implementation VNProtocol {
    /// Serialises every piece of state below. Delegate callbacks arrive on
    /// the session's queue and timer ticks on a global queue, so the pacing
    /// state needs one owner.
    dispatch_queue_t _queue;
    NSURLSessionDataTask *_task;
    NSMutableData *_pending;
    dispatch_source_t _timer;
    BOOL _upstreamDone;
    BOOL _finished;
    BOOL _suspended;
    NSError *_upstreamError;
    long _bytesPerTick;
    double _tickIntervalMs;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:kVNHandled inRequest:request]) return NO;
    // Nothing published, or a condition that changes nothing: leave the
    // request entirely alone. Intercepting and re-issuing "unconditioned"
    // would still move every byte through this class, and an app that isn't
    // being conditioned should pay nothing for the dylib being loaded.
    VNCondition condition = VNConditionCurrent();
    if (!condition.conditioning) return NO;

    NSString *scheme = request.URL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;

    // A WebSocket handshake arrives here as an ordinary https GET — the
    // `wss:` scheme is already gone by the time a URLProtocol sees it. Taking
    // it would be worse than useless: we re-issue through a data task, the
    // Upgrade never completes, and every WebSocket in the app fails to
    // connect the moment any condition is armed. Messages are conditioned by
    // the hooks in VirtualNetworkWebSocket.m instead, which is the only layer
    // where a WebSocket is still a WebSocket.
    if (VNIsWebSocketUpgrade(request)) {
        VNLogThrottled("ws-upgrade",
                       @"[VirtualNetwork] leaving a websocket handshake alone: %@",
                       request.URL.absoluteString);
        return NO;
    }
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    VNCondition condition = VNConditionCurrent();

    if (condition.offline) {
        [self vn_failWith:NSURLErrorNotConnectedToInternet reason:@"offline"];
        return;
    }
    if (condition.lossPercent > 0
        && arc4random_uniform(100) < (uint32_t)condition.lossPercent) {
        [self vn_failWith:NSURLErrorNetworkConnectionLost reason:@"loss"];
        return;
    }

    _queue = dispatch_queue_create("com.baguette.network.protocol", DISPATCH_QUEUE_SERIAL);
    _pending = [NSMutableData data];
    _bytesPerTick = condition.bytesPerTick;
    _tickIntervalMs = condition.tickIntervalMs;

    // The body arrives as `HTTPBodyStream`, never as `HTTPBody` — measured,
    // and the reason this must never retry: a stream can be read exactly
    // once, so a second attempt would send an empty body and read as a
    // server bug rather than as a failed request. `mutableCopy` carries the
    // stream across intact.
    NSMutableURLRequest *inner = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kVNHandled inRequest:inner];

    VNLogThrottled("request", @"[VirtualNetwork] conditioning %@ %@",
                   self.request.HTTPMethod, self.request.URL.absoluteString);

    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(condition.latencyMs * NSEC_PER_MSEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            dispatch_async(self->_queue, ^{
                if (self->_finished) return;
                self->_task = [VNSharedSession() dataTaskWithRequest:inner];
                [VNSessionDelegate.shared adopt:self forTask:self->_task];
                [self->_task resume];
            });
        });
}

- (void)stopLoading {
    // `_queue` is nil when the request failed before any of the pacing
    // machinery was built.
    if (!_queue) return;
    dispatch_async(_queue, ^{
        self->_finished = YES;
        [self->_task cancel];
        [self vn_cancelTimer];
    });
}

- (void)vn_failWith:(NSInteger)code reason:(NSString *)reason {
    VNLogThrottled(reason.UTF8String, @"[VirtualNetwork] failing %@ as %@ (NSURLError %ld)",
                   self.request.URL.absoluteString, reason, (long)code);
    [self.client URLProtocol:self
            didFailWithError:[NSError errorWithDomain:NSURLErrorDomain
                                                 code:code
                                             userInfo:nil]];
}

#pragma mark Upstream callbacks

- (void)vn_didReceiveResponse:(NSURLResponse *)response {
    // Forwarded immediately: the headers are not what's being paced, and an
    // app that sizes a progress bar from Content-Length should get to do so
    // before the body starts trickling in.
    [self.client URLProtocol:self
          didReceiveResponse:response
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
}

- (void)vn_didReceiveData:(NSData *)data {
    dispatch_async(_queue, ^{
        if (self->_finished) return;
        if (self->_bytesPerTick <= 0) {
            // Unmetered: latency and loss still applied, but bytes are
            // handed straight on.
            [self.client URLProtocol:self didLoadData:data];
            return;
        }
        [self->_pending appendData:data];
        [self vn_startTimerIfNeeded];
        [self vn_applyBackpressure];
    });
}

- (void)vn_didCompleteWithError:(NSError *)error {
    dispatch_async(_queue, ^{
        if (self->_finished) return;
        self->_upstreamError = error;
        self->_upstreamDone = YES;
        // A failure ends it now — there is no point pacing out a backlog
        // that is about to be replaced by an error.
        if (error || self->_bytesPerTick <= 0 || self->_pending.length == 0) {
            [self vn_finish];
        }
    });
}

#pragma mark Pacing

- (void)vn_startTimerIfNeeded {
    if (_timer) return;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    uint64_t interval = (uint64_t)(_tickIntervalMs * NSEC_PER_MSEC);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval, interval / 10);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf vn_drainOneTick]; });
    dispatch_resume(_timer);
}

- (void)vn_drainOneTick {
    if (_finished) return;
    NSUInteger take = MIN((NSUInteger)_bytesPerTick, _pending.length);
    if (take > 0) {
        [self.client URLProtocol:self
                     didLoadData:[_pending subdataWithRange:NSMakeRange(0, take)]];
        [_pending replaceBytesInRange:NSMakeRange(0, take) withBytes:NULL length:0];
    }
    [self vn_applyBackpressure];
    if (_upstreamDone && _pending.length == 0) [self vn_finish];
}

- (void)vn_applyBackpressure {
    if (!_task) return;
    if (!_suspended && _pending.length >= kHighWaterBytes) {
        _suspended = YES;
        [_task suspend];
    } else if (_suspended && _pending.length <= kLowWaterBytes) {
        _suspended = NO;
        [_task resume];
    }
}

- (void)vn_cancelTimer {
    if (!_timer) return;
    dispatch_source_cancel(_timer);
    _timer = nil;
}

- (void)vn_finish {
    if (_finished) return;
    _finished = YES;
    [self vn_cancelTimer];
    if (_upstreamError) {
        [self.client URLProtocol:self didFailWithError:_upstreamError];
    } else {
        [self.client URLProtocolDidFinishLoading:self];
    }
}

@end
