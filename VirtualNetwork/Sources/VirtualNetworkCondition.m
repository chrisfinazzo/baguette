#import "VirtualNetworkCondition.h"
#import <sys/stat.h>
#import <os/lock.h>
#import <os/log.h>

NSString *const VNConditionPath = @"/tmp/BaguetteNetwork.json";

/// How often the file is stat'ed. Every request asks, and an app under test
/// can make hundreds a minute, so this keeps a hot path from stat'ing on
/// each one; the condition itself changes only when someone changes it.
static const double kStatInterval = 0.1;

static VNCondition gCached;
static double gLastStat;
static long gLastMtime;
static long gLastSize;
static uint64_t gGeneration;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

static double VNNow(void) {
    return [NSDate date].timeIntervalSince1970;
}

void VNLog(NSString *format, ...) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logger = os_log_create("com.baguette.network", "inject");
    });
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(logger, "%{public}s", message.UTF8String);
}

void VNLogThrottled(const char *key, NSString *format, ...) {
    static NSMutableDictionary<NSString *, NSNumber *> *last;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ last = [NSMutableDictionary dictionary]; });

    NSString *bucket = @(key);
    double now = VNNow();
    os_unfair_lock_lock(&lock);
    BOOL emit = now - last[bucket].doubleValue >= 1.0;
    if (emit) last[bucket] = @(now);
    os_unfair_lock_unlock(&lock);
    if (!emit) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    VNLog(@"%@", message);
}

static VNCondition VNParse(NSData *data) {
    VNCondition condition = {0};
    if (data.length == 0) return condition;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:NSDictionary.class]) return condition;

    condition.valid = YES;
    condition.latencyMs = [json[@"latencyMs"] doubleValue];
    condition.lossPercent = [json[@"lossPercent"] doubleValue];
    condition.offline = [json[@"offline"] boolValue];

    // Absent `pacing` means unmetered — the host omits the key rather than
    // sending a zero it would then have to disambiguate.
    NSDictionary *pacing = json[@"pacing"];
    if ([pacing isKindOfClass:NSDictionary.class]) {
        condition.bytesPerTick = [pacing[@"bytesPerTick"] longValue];
        condition.tickIntervalMs = [pacing[@"tickIntervalMs"] doubleValue];
    }

    condition.conditioning = condition.offline
        || condition.latencyMs > 0
        || condition.lossPercent > 0
        || condition.bytesPerTick > 0;
    return condition;
}

VNCondition VNConditionCurrent(void) {
    os_unfair_lock_lock(&gLock);
    double now = VNNow();
    if (now - gLastStat >= kStatInterval) {
        gLastStat = now;
        struct stat st;
        if (stat(VNConditionPath.fileSystemRepresentation, &st) == 0) {
            // Re-parse only when the file actually moved. The host writes
            // atomically, so a replacement shows up as a new mtime/size and
            // we never read a half-written condition.
            if (st.st_mtimespec.tv_sec != gLastMtime || st.st_size != gLastSize) {
                gLastMtime = st.st_mtimespec.tv_sec;
                gLastSize = st.st_size;
                NSData *data = [NSData dataWithContentsOfFile:VNConditionPath];
                gCached = VNParse(data);
                gCached.generation = ++gGeneration;
                if (gCached.conditioning) {
                    VNLog(@"[VirtualNetwork] conditioning: %@%.0f ms latency, "
                          @"%ld bytes/%.0f ms, %.0f%% loss",
                          gCached.offline ? @"OFFLINE, " : @"",
                          gCached.latencyMs, gCached.bytesPerTick,
                          gCached.tickIntervalMs, gCached.lossPercent);
                } else {
                    VNLog(@"[VirtualNetwork] conditioning cleared — requests are "
                          @"no longer being touched");
                }
            }
        } else {
            // Nothing published. Leave every request completely alone
            // rather than intercepting and re-issuing at full speed: an app
            // that isn't being conditioned should be paying nothing for
            // this dylib being loaded.
            VNCondition empty = {0};
            empty.generation = gGeneration;
            gCached = empty;
            gLastMtime = 0;
            gLastSize = 0;
        }
    }
    VNCondition condition = gCached;
    os_unfair_lock_unlock(&gLock);
    return condition;
}
