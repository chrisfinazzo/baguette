#import "VirtualMotionIntent.h"
#import <sys/stat.h>
#import <os/lock.h>

/// The intent path for *this* simulator.
///
/// Every simulator sees the host's `/tmp`, so a single shared file meant a
/// publish for one device replaced the intent an injected app on another was
/// still reading. `SIMULATOR_UDID` is set in every process the simulator
/// launches, so both sides can derive the same per-device path.
///
/// With no UDID there is nothing safe to read — guessing would mean serving
/// another simulator's motion — so the path stays nil and every surface
/// reports no motion.
NSString *VMIntentPath(void) {
    static NSString *path;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *udid = getenv("SIMULATOR_UDID");
        path = udid ? [NSString stringWithFormat:@"/tmp/BaguetteMotion-%s.json", udid] : nil;
    });
    return path;
}

/// How often the file is stat'ed. Sampling runs at up to 100 Hz, so this
/// keeps a hot loop from stat'ing on every tick; the intent itself changes
/// only when the device changes what it's doing.
static const double kStatInterval = 0.1;

/// Vehicle / road vibration frequency, used when the kind takes no steps but
/// still moves. A car ride that reads perfectly still is less useful than one
/// that reads like a car ride.
static const double kRoadHz = 12.0;

static VMIntent gCached;
static double gLastStat;
static struct timespec gLastMtime;
static long gLastSize;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

static double VMNow(void) {
    return [NSDate date].timeIntervalSince1970;
}

static VMIntent VMParse(NSData *data) {
    VMIntent intent = {0};
    if (data.length == 0) return intent;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![json isKindOfClass:NSDictionary.class]) return intent;
    NSDictionary *profile = json[@"profile"];
    if (![profile isKindOfClass:NSDictionary.class]) return intent;

    intent.activityType = [json[@"activityType"] intValue];
    intent.confidence = [json[@"confidence"] intValue];
    intent.speed = [json[@"speed"] doubleValue];
    intent.startedAt = [json[@"startedAt"] doubleValue];
    // A missing or zero `startedAt` would make the leg integrate from 1970
    // and report a preposterous step count on the first pedometer read.
    // Treat a payload without it — truncated, or simply not ours — as no
    // motion at all rather than as motion since the epoch.
    if (intent.startedAt <= 0) {
        VMIntent invalid = {0};
        return invalid;
    }
    intent.stepsBefore = [json[@"stepsBefore"] longValue];
    intent.distanceBefore = [json[@"distanceBefore"] doubleValue];
    intent.cadenceHz = [profile[@"cadenceHz"] doubleValue];
    intent.gaitAmplitude = [profile[@"gaitAmplitude"] doubleValue];
    intent.strideMetres = [profile[@"strideMetres"] doubleValue];
    intent.valid = YES;
    return intent;
}

VMIntent VMIntentCurrent(void) {
    NSString *path = VMIntentPath();
    if (!path) {
        VMIntent none = {0};
        return none;
    }
    os_unfair_lock_lock(&gLock);
    double now = VMNow();
    if (now - gLastStat >= kStatInterval) {
        gLastStat = now;
        struct stat st;
        if (stat(path.fileSystemRepresentation, &st) == 0) {
            // Re-parse only when the file actually moved. The host writes
            // atomically, so a replacement shows up as a new mtime/size and
            // we never read a half-written intent.
            //
            // Nanoseconds matter here: a republish fires on a 0.1 m/s speed
            // change, which can leave the JSON exactly as long as before
            // (1.4 -> 1.5), so a whole-second mtime plus a byte count would
            // call a genuinely new intent unchanged.
            if (st.st_mtimespec.tv_sec != gLastMtime.tv_sec
                || st.st_mtimespec.tv_nsec != gLastMtime.tv_nsec
                || st.st_size != gLastSize) {
                gLastMtime = st.st_mtimespec;
                gLastSize = st.st_size;
                NSData *data = [NSData dataWithContentsOfFile:path];
                gCached = VMParse(data);
            }
        } else {
            // Nothing published yet. Report no motion rather than inventing
            // some: an app polling before the first publish should see
            // stillness, not a phantom walk.
            VMIntent empty = {0};
            gCached = empty;
            gLastMtime = (struct timespec){0};
            gLastSize = 0;
        }
    }
    VMIntent intent = gCached;
    os_unfair_lock_unlock(&gLock);
    return intent;
}

/// Whole steps taken in the leg running at `now`. Half a step has not been
/// taken, and a leg that appears to run backwards (clock skew) contributes
/// nothing — a cumulative counter must never rewind.
static long VMLegSteps(VMIntent intent, double now) {
    if (!intent.valid || intent.cadenceHz <= 0) return 0;
    double elapsed = now - intent.startedAt;
    if (elapsed <= 0) return 0;
    return (long)floor(intent.cadenceHz * elapsed);
}

long VMIntentSteps(VMIntent intent, double now) {
    if (!intent.valid) return 0;
    return intent.stepsBefore + VMLegSteps(intent, now);
}

double VMIntentDistance(VMIntent intent, double now) {
    if (!intent.valid) return 0;
    return intent.distanceBefore + (double)VMLegSteps(intent, now) * intent.strideMetres;
}

double VMIntentShakeHz(VMIntent intent) {
    if (!intent.valid) return 0;
    return intent.cadenceHz > 0 ? intent.cadenceHz : kRoadHz;
}
