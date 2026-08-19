// SpikeNet — throwaway probe for the network-conditioning plan's section 4.
//
// Answers, against a real RN app in a booted simulator:
//   1. Does a URLProtocol registered from a dylib constructor intercept RN's fetch?
//   2. Is +registerClass: enough, or is the URLSessionConfiguration getter swizzle needed?
//   3. Does a recursion guard hold when the inner request re-enters?
//   4. Does chunked client:didLoadData: actually pace the app's download?
//   5. What is NOT intercepted?
//
// Mode is read from /tmp/SpikeNet.mode: "register" | "swizzle" | "both" (default).
// Knobs from /tmp/SpikeNet.json. os_log only — never NSLog (an injected NSLog
// pollutes the stdout of every spawned process, including launchctl).

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <os/lock.h>
#import <sys/stat.h>

static void SNLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void SNLog(NSString *format, ...) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logger = os_log_create("com.baguette.network", "spike"); });
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(logger, "%{public}s", message.UTF8String);
}

#pragma mark - Knobs

static double gLatencyMs = 2000;
static long gChunks = 10;
static double gChunkIntervalMs = 300;
static double gLossPercent = 0;
static BOOL gOffline = NO;

static void SNLoadKnobs(void) {
    NSData *data = [NSData dataWithContentsOfFile:@"/tmp/SpikeNet.json"];
    if (!data.length) return;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:NSDictionary.class]) return;
    if (json[@"latencyMs"]) gLatencyMs = [json[@"latencyMs"] doubleValue];
    if (json[@"chunks"]) gChunks = [json[@"chunks"] longValue];
    if (json[@"chunkIntervalMs"]) gChunkIntervalMs = [json[@"chunkIntervalMs"] doubleValue];
    if (json[@"lossPercent"]) gLossPercent = [json[@"lossPercent"] doubleValue];
    if (json[@"offline"]) gOffline = [json[@"offline"] boolValue];
}

/// Re-read the knobs when the file moves, the way `VMIntentCurrent` polls the
/// motion intent. Proves the real feature can change condition without
/// relaunching the app — only the initial arm needs the relaunch.
static void SNRefreshKnobs(void) {
    static double lastStat;
    static long lastMtime, lastSize;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    os_unfair_lock_lock(&lock);
    double now = NSDate.date.timeIntervalSince1970;
    if (now - lastStat >= 0.1) {
        lastStat = now;
        struct stat st;
        if (stat("/tmp/SpikeNet.json", &st) == 0 &&
            (st.st_mtimespec.tv_sec != lastMtime || st.st_size != lastSize)) {
            lastMtime = st.st_mtimespec.tv_sec;
            lastSize = st.st_size;
            SNLoadKnobs();
            SNLog(@"[SpikeNet] knobs reloaded — latency=%.0fms loss=%.0f%% offline=%d",
                  gLatencyMs, gLossPercent, gOffline);
        }
    }
    os_unfair_lock_unlock(&lock);
}

static NSString *SNMode(void) {
    NSString *mode = [NSString stringWithContentsOfFile:@"/tmp/SpikeNet.mode"
                                               encoding:NSUTF8StringEncoding error:NULL];
    mode = [mode stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return mode.length ? mode : @"both";
}

#pragma mark - The protocol

static NSString *const kHandledKey = @"SpikeNetHandled";

@interface SNProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *body;
@property (nonatomic, strong) NSURLResponse *upstreamResponse;
@property (nonatomic) double startedAt;
@end

@implementation SNProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:kHandledKey inRequest:request]) {
        // Spike 3: this is the recursion guard doing its job. Logged so a
        // silent infinite loop can't be mistaken for "it just works".
        SNLog(@"[SpikeNet] guard: declining our own re-issued %@", request.URL.absoluteString);
        return NO;
    }
    NSString *scheme = request.URL.scheme.lowercaseString;
    BOOL http = [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"];
    SNLog(@"[SpikeNet] canInit %@ %@ -> %@", request.HTTPMethod, request.URL.absoluteString,
          http ? @"YES" : @"NO");
    return http;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    SNRefreshKnobs();
    self.startedAt = NSDate.date.timeIntervalSince1970;
    NSURLRequest *original = self.request;
    SNLog(@"[SpikeNet] INTERCEPTED %@ %@ (latency %.0fms loss %.0f%% offline %d)",
          original.HTTPMethod, original.URL.absoluteString, gLatencyMs, gLossPercent, gOffline);

    // Spike: NSURLProtocol is documented to hand over POST bodies as a stream
    // rather than HTTPBody, and a stream can only be read once — re-issuing
    // the request without noticing would silently send an empty body. Log
    // exactly what arrived so the trap is measured, not assumed.
    if (original.HTTPBody.length || original.HTTPBodyStream) {
        SNLog(@"[SpikeNet] body for %@ %@: HTTPBody=%lu bytes, HTTPBodyStream=%@",
              original.HTTPMethod, original.URL.absoluteString,
              (unsigned long)original.HTTPBody.length,
              original.HTTPBodyStream ? @"present" : @"nil");
    } else if ([original.HTTPMethod isEqualToString:@"POST"] ||
               [original.HTTPMethod isEqualToString:@"PUT"] ||
               [original.HTTPMethod isEqualToString:@"PATCH"]) {
        SNLog(@"[SpikeNet] WARNING %@ %@ arrived with NO body at all "
              @"(Content-Length header says %@)",
              original.HTTPMethod, original.URL.absoluteString,
              [original valueForHTTPHeaderField:@"Content-Length"] ?: @"(unset)");
    }

    if (gOffline) {
        [self failWith:NSURLErrorNotConnectedToInternet reason:@"offline"];
        return;
    }
    if (gLossPercent > 0 && (arc4random_uniform(100) < (uint32_t)gLossPercent)) {
        [self failWith:NSURLErrorNetworkConnectionLost reason:@"loss"];
        return;
    }

    NSMutableURLRequest *inner = [original mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandledKey inRequest:inner];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gLatencyMs * NSEC_PER_MSEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config
                                                             delegate:self
                                                        delegateQueue:nil];
        self.task = [session dataTaskWithRequest:inner];
        [self.task resume];
    });
}

- (void)failWith:(NSInteger)code reason:(NSString *)reason {
    SNLog(@"[SpikeNet] failing %@ as %@ (NSURLError %ld)", self.request.URL.absoluteString,
          reason, (long)code);
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:code userInfo:nil];
    [self.client URLProtocol:self didFailWithError:error];
}

- (void)stopLoading { [self.task cancel]; }

#pragma mark NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.upstreamResponse = response;
    self.body = [NSMutableData data];
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        // A POST whose body we dropped shows up here as a 4xx the app would
        // never have got on its own — the cheapest tell that interception
        // corrupted the request rather than merely slowing it.
        SNLog(@"[SpikeNet] upstream %ld for %@ %@",
              (long)((NSHTTPURLResponse *)response).statusCode,
              self.request.HTTPMethod, self.request.URL.absoluteString);
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    [self.body appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error) {
        SNLog(@"[SpikeNet] upstream failed %@: %@", self.request.URL.absoluteString,
              error.localizedDescription);
        [self.client URLProtocol:self didFailWithError:error];
        return;
    }
    [self.client URLProtocol:self didReceiveResponse:self.upstreamResponse
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self deliverChunked];
}

/// Spike 4: hand the body over in timed slices rather than all at once, and
/// see whether the app observes a paced download or one late blob.
- (void)deliverChunked {
    NSData *body = self.body ?: NSData.data;
    long chunks = gChunks > 0 ? gChunks : 1;
    NSUInteger size = (NSUInteger)ceil((double)body.length / (double)chunks);
    if (size == 0) {
        [self.client URLProtocolDidFinishLoading:self];
        SNLog(@"[SpikeNet] delivered empty body for %@", self.request.URL.absoluteString);
        return;
    }
    __block NSUInteger offset = 0;
    __block long index = 0;
    dispatch_queue_t queue = dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
    __block void (^next)(void);
    next = ^{
        if (offset >= body.length) {
            double elapsed = NSDate.date.timeIntervalSince1970 - self.startedAt;
            SNLog(@"[SpikeNet] finished %@ — %lu bytes in %ld chunks over %.2fs",
                  self.request.URL.absoluteString, (unsigned long)body.length, index, elapsed);
            [self.client URLProtocolDidFinishLoading:self];
            next = nil;
            return;
        }
        NSUInteger length = MIN(size, body.length - offset);
        [self.client URLProtocol:self
                     didLoadData:[body subdataWithRange:NSMakeRange(offset, length)]];
        offset += length;
        index += 1;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(gChunkIntervalMs * NSEC_PER_MSEC)),
                       queue, ^{ next(); });
    };
    next();
}

@end

#pragma mark - Configuration getter swizzle

static IMP gOrigDefault;
static IMP gOrigEphemeral;

static NSURLSessionConfiguration *SNInject(NSURLSessionConfiguration *config) {
    if (!config) return config;
    NSMutableArray *classes = [config.protocolClasses mutableCopy] ?: NSMutableArray.array;
    if (![classes containsObject:SNProtocol.class]) {
        [classes insertObject:SNProtocol.class atIndex:0];
        config.protocolClasses = classes;
    }
    return config;
}

static id SNDefaultConfig(id self, SEL _cmd) {
    return SNInject(((id (*)(id, SEL))gOrigDefault)(self, _cmd));
}
static id SNEphemeralConfig(id self, SEL _cmd) {
    return SNInject(((id (*)(id, SEL))gOrigEphemeral)(self, _cmd));
}

static void SNInstallConfigSwizzle(void) {
    Class cls = objc_getClass("NSURLSessionConfiguration");
    if (!cls) { SNLog(@"[SpikeNet] no NSURLSessionConfiguration class"); return; }

    Method def = class_getClassMethod(cls, @selector(defaultSessionConfiguration));
    if (def) {
        gOrigDefault = method_getImplementation(def);
        method_setImplementation(def, (IMP)SNDefaultConfig);
    }
    Method eph = class_getClassMethod(cls, @selector(ephemeralSessionConfiguration));
    if (eph) {
        gOrigEphemeral = method_getImplementation(eph);
        method_setImplementation(eph, (IMP)SNEphemeralConfig);
    }
    SNLog(@"[SpikeNet] config swizzle installed (default=%d ephemeral=%d)",
          def != NULL, eph != NULL);
}

#pragma mark - Load

__attribute__((constructor)) static void SpikeNetInit(void) {
    SNLoadKnobs();
    NSString *mode = SNMode();
    SNLog(@"[SpikeNet] loading into %@ — mode=%@ latency=%.0fms chunks=%ld/%.0fms "
          @"loss=%.0f%% offline=%d",
          NSProcessInfo.processInfo.processName, mode, gLatencyMs, gChunks,
          gChunkIntervalMs, gLossPercent, gOffline);

    if ([mode isEqualToString:@"register"] || [mode isEqualToString:@"both"]) {
        BOOL ok = [NSURLProtocol registerClass:SNProtocol.class];
        SNLog(@"[SpikeNet] registerClass -> %@", ok ? @"YES" : @"NO");
    }
    if ([mode isEqualToString:@"swizzle"] || [mode isEqualToString:@"both"]) {
        SNInstallConfigSwizzle();
    }
}
