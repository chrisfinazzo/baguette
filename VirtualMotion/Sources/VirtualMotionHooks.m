// VirtualMotionHooks — the swizzles that make CoreMotion answer from
// baguette's published intent instead of from hardware that doesn't exist.
//
// Three surfaces, all reporting unavailable in a stock simulator:
//   CMMotionActivityManager — walking / running / cycling / automotive
//   CMPedometer             — steps, distance, pace, cadence
//   CMMotionManager         — accelerometer, gyro, device motion
//
// Each is installed only if `VMFactorySelfCheck` could build and verify that
// surface's objects. If a future iOS moves the private layout, the app sees
// the platform's honest "unavailable" rather than our garbage.

#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import "VirtualMotionIntent.h"
#import "VirtualMotionFactory.h"

/// Diagnostics go to the unified log **only** — never NSLog.
///
/// This dylib is loaded into *every* process launched in the simulator while
/// motion is armed, including the short-lived `launchctl` that baguette
/// spawns to read `DYLD_INSERT_LIBRARIES`. NSLog writes to stderr, and the
/// simulator's stdout/stderr channel carries leftovers between spawned
/// processes, so a banner printed here can come back as part of the value
/// baguette is trying to read. `InjectedDylibs.parsing` defends against that
/// too, but the dylib has no business writing to a host process's streams in
/// the first place. Read these with:
///   xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.baguette.motion"'
static void VMLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void VMLog(NSString *format, ...) {
    static os_log_t logger;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logger = os_log_create("com.baguette.motion", "inject");
    });
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    os_log(logger, "%{public}s", message.UTF8String);
}

static const double kDefaultInterval = 1.0 / 60.0;
static const double kMinInterval = 0.01;         // 100 Hz ceiling
static const double kActivityPollInterval = 0.25;
static const double kPedometerInterval = 1.0;

static double VMNow(void) { return [NSDate date].timeIntervalSince1970; }

static void VMReplace(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

static void VMReplaceClassMethod(Class cls, SEL sel, IMP imp) {
    Method m = class_getClassMethod(cls, sel);
    if (m) method_setImplementation(m, imp);
}

#pragma mark - Synthesised sample maths

/// The gait signal at `now`: a sine at footfall cadence scaled by the
/// profile's amplitude. Vertical (z) carries the bulk of it, with smaller
/// lateral components so an app looking at x/y sees something plausible.
static void VMGait(VMIntent intent, double now, double *ax, double *ay, double *az) {
    double hz = VMIntentShakeHz(intent);
    double amp = intent.valid ? intent.gaitAmplitude : 0;
    if (hz <= 0 || amp <= 0) { *ax = *ay = *az = 0; return; }
    double phase = 2 * M_PI * hz * now;
    *az = amp * sin(phase);
    *ax = amp * 0.35 * sin(phase * 0.5);
    *ay = amp * 0.25 * cos(phase);
}

/// Rotation in radians/s, in step with the gait — a device swinging slightly
/// with each footfall.
static void VMRotation(VMIntent intent, double now, double *rx, double *ry, double *rz) {
    double hz = VMIntentShakeHz(intent);
    double amp = intent.valid ? intent.gaitAmplitude : 0;
    if (hz <= 0 || amp <= 0) { *rx = *ry = *rz = 0; return; }
    double phase = 2 * M_PI * hz * now;
    *rx = amp * 0.6 * cos(phase);
    *ry = amp * 0.4 * sin(phase);
    *rz = amp * 0.2 * sin(phase * 0.5);
}

#pragma mark - CMMotionActivityManager

static NSOperationQueue *gActivityQueue;
static CMMotionActivityHandler gActivityHandler;
static int32_t gLastActivityType = INT32_MIN;
static dispatch_source_t gActivityTimer;

static void VMDeliverActivity(BOOL force) {
    if (!gActivityHandler || !gActivityQueue) return;
    VMIntent intent = VMIntentCurrent();
    if (!force && intent.activityType == gLastActivityType) return;
    gLastActivityType = intent.activityType;
    CMMotionActivityHandler handler = gActivityHandler;
    CMMotionActivity *activity = VMMakeActivity(intent.activityType, intent.confidence,
                                                NSDate.date);
    if (!activity) return;
    // Transitions only, so this stays quiet — and a transition is exactly
    // what an app waiting to leave "stationary" is listening for.
    VMLog(@"[VirtualMotion] delivering activity type %d to the app", intent.activityType);
    [gActivityQueue addOperationWithBlock:^{ handler(activity); }];
}

static BOOL VMActivityAvailable(id self, SEL _cmd) { return YES; }
static NSInteger VMMotionAuthorized(id self, SEL _cmd) { return 3; /* authorized */ }

static void VMStartActivityUpdates(id self, SEL _cmd, NSOperationQueue *queue,
                                   CMMotionActivityHandler handler) {
    // Logged because "my app sees nothing" has two very different causes:
    // the dylib not being loaded, and the app never subscribing. Without
    // this line they look identical from outside.
    VMLog(@"[VirtualMotion] app subscribed to activity updates");
    gActivityQueue = queue;
    gActivityHandler = handler;
    gLastActivityType = INT32_MIN;
    VMDeliverActivity(YES);
    if (gActivityTimer) return;
    gActivityTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(gActivityTimer, DISPATCH_TIME_NOW,
                              (uint64_t)(kActivityPollInterval * NSEC_PER_SEC),
                              (uint64_t)(0.05 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(gActivityTimer, ^{ VMDeliverActivity(NO); });
    dispatch_resume(gActivityTimer);
}

static void VMStopActivityUpdates(id self, SEL _cmd) {
    gActivityHandler = nil;
    gActivityQueue = nil;
}

static void VMQueryActivity(id self, SEL _cmd, NSDate *from, NSDate *to,
                            NSOperationQueue *queue, CMMotionActivityQueryHandler handler) {
    VMIntent intent = VMIntentCurrent();
    CMMotionActivity *activity = VMMakeActivity(intent.activityType, intent.confidence, from);
    NSArray *result = activity ? @[activity] : @[];
    [queue addOperationWithBlock:^{ handler(result, nil); }];
}

#pragma mark - CMPedometer

/// Per-pedometer state. Held as an associated object so several pedometers
/// can run at once without a shared registry.
@interface VMPedometerState : NSObject
@property (nonatomic, strong) NSDate *from;
@property (nonatomic, strong) dispatch_source_t timer;
@end
@implementation VMPedometerState
@end

static const void *kPedometerStateKey = &kPedometerStateKey;

static CMPedometerData *VMPedometerSnapshot(NSDate *from, NSDate *to) {
    VMIntent intent = VMIntentCurrent();
    double now = to.timeIntervalSince1970;
    long steps = VMIntentSteps(intent, now);
    double metres = VMIntentDistance(intent, now);
    return VMMakePedometerData(from, to, steps, metres, intent.cadenceHz, intent.speed);
}

static BOOL VMPedometerYes(id self, SEL _cmd) { return YES; }
/// Floors need barometric altitude, which no published intent carries. Saying
/// so is better than reporting a fabricated storey count.
static BOOL VMPedometerNo(id self, SEL _cmd) { return NO; }

static void VMStartPedometerUpdates(id self, SEL _cmd, NSDate *from,
                                    CMPedometerHandler handler) {
    VMLog(@"[VirtualMotion] app subscribed to pedometer updates");
    VMPedometerState *state = [VMPedometerState new];
    state.from = from ?: NSDate.date;
    objc_setAssociatedObject(self, kPedometerStateKey, state, OBJC_ASSOCIATION_RETAIN);

    void (^tick)(void) = ^{
        CMPedometerData *data = VMPedometerSnapshot(state.from, NSDate.date);
        if (data) handler(data, nil);
    };
    tick();
    state.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                         dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(state.timer, DISPATCH_TIME_NOW,
                              (uint64_t)(kPedometerInterval * NSEC_PER_SEC),
                              (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(state.timer, tick);
    dispatch_resume(state.timer);
}

static void VMStopPedometerUpdates(id self, SEL _cmd) {
    VMPedometerState *state = objc_getAssociatedObject(self, kPedometerStateKey);
    if (state.timer) dispatch_source_cancel(state.timer);
    objc_setAssociatedObject(self, kPedometerStateKey, nil, OBJC_ASSOCIATION_RETAIN);
}

static void VMQueryPedometer(id self, SEL _cmd, NSDate *from, NSDate *to,
                             CMPedometerHandler handler) {
    CMPedometerData *data = VMPedometerSnapshot(from, to);
    handler(data, nil);
}

#pragma mark - CMMotionManager

/// Which streams a given manager has running, and the timers feeding them.
@interface VMManagerState : NSObject
@property (nonatomic) BOOL accelerometerActive;
@property (nonatomic) BOOL gyroActive;
@property (nonatomic) BOOL deviceMotionActive;
@property (nonatomic, strong) dispatch_source_t accelerometerTimer;
@property (nonatomic, strong) dispatch_source_t gyroTimer;
@property (nonatomic, strong) dispatch_source_t deviceMotionTimer;
@end
@implementation VMManagerState
@end

static const void *kManagerStateKey = &kManagerStateKey;

static VMManagerState *VMState(id manager) {
    VMManagerState *state = objc_getAssociatedObject(manager, kManagerStateKey);
    if (!state) {
        state = [VMManagerState new];
        objc_setAssociatedObject(manager, kManagerStateKey, state, OBJC_ASSOCIATION_RETAIN);
    }
    return state;
}

static double VMClampInterval(double interval) {
    if (interval <= 0) return kDefaultInterval;
    return interval < kMinInterval ? kMinInterval : interval;
}

static dispatch_source_t VMTimer(double interval, dispatch_block_t block) {
    dispatch_source_t timer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW,
                              (uint64_t)(interval * NSEC_PER_SEC),
                              (uint64_t)(interval * 0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, block);
    dispatch_resume(timer);
    return timer;
}

static CMAccelerometerData *VMCurrentAccelerometerData(void) {
    VMIntent intent = VMIntentCurrent();
    double now = VMNow();
    double ax, ay, az;
    VMGait(intent, now, &ax, &ay, &az);
    // Raw accelerometer readings include gravity; a phone held upright reads
    // about -1 g on z. Device motion is where the two are separated.
    return VMMakeAccelerometerData(ax, ay, az - 1.0,
                                   NSProcessInfo.processInfo.systemUptime);
}

static CMGyroData *VMCurrentGyroData(void) {
    VMIntent intent = VMIntentCurrent();
    double rx, ry, rz;
    VMRotation(intent, VMNow(), &rx, &ry, &rz);
    return VMMakeGyroData(rx, ry, rz, NSProcessInfo.processInfo.systemUptime);
}

static CMDeviceMotion *VMCurrentDeviceMotion(void) {
    VMIntent intent = VMIntentCurrent();
    double now = VMNow();
    double ax, ay, az, rx, ry, rz;
    VMGait(intent, now, &ax, &ay, &az);
    VMRotation(intent, now, &rx, &ry, &rz);
    // userAcceleration excludes gravity by definition, so the gait signal is
    // handed over as-is; gravity comes from the level attitude.
    return VMMakeDeviceMotion(ax, ay, az, rx, ry, rz,
                              NSProcessInfo.processInfo.systemUptime);
}

static BOOL VMManagerYes(id self, SEL _cmd) { return YES; }
/// The magnetometer stays unavailable on purpose. A magnetic-field vector
/// implies a compass heading, and CLHeading is documented as impossible in
/// the simulator — inventing a field would make an app trust a bearing that
/// means nothing. Gait acceleration follows from walking; a heading doesn't.
static BOOL VMManagerNo(id self, SEL _cmd) { return NO; }

static BOOL VMAccelerometerActive(id self, SEL _cmd) { return VMState(self).accelerometerActive; }
static BOOL VMGyroActive(id self, SEL _cmd) { return VMState(self).gyroActive; }
static BOOL VMDeviceMotionActive(id self, SEL _cmd) { return VMState(self).deviceMotionActive; }

static id VMAccelerometerDataProperty(id self, SEL _cmd) {
    return VMState(self).accelerometerActive ? VMCurrentAccelerometerData() : nil;
}
static id VMGyroDataProperty(id self, SEL _cmd) {
    return VMState(self).gyroActive ? VMCurrentGyroData() : nil;
}
static id VMDeviceMotionProperty(id self, SEL _cmd) {
    return VMState(self).deviceMotionActive ? VMCurrentDeviceMotion() : nil;
}
static id VMMagnetometerDataProperty(id self, SEL _cmd) { return nil; }

// Pull model — `start…Updates` with no queue, then read the property.
static void VMStartAccelerometerPull(id self, SEL _cmd) { VMState(self).accelerometerActive = YES; }
static void VMStartGyroPull(id self, SEL _cmd) { VMState(self).gyroActive = YES; }
static void VMStartDeviceMotionPull(id self, SEL _cmd) { VMState(self).deviceMotionActive = YES; }

// Push model — deliver on the caller's queue at its requested interval.
static void VMStartAccelerometerUpdates(id self, SEL _cmd, NSOperationQueue *queue,
                                        CMAccelerometerHandler handler) {
    VMLog(@"[VirtualMotion] app subscribed to accelerometer updates");
    VMManagerState *state = VMState(self);
    state.accelerometerActive = YES;
    double interval = VMClampInterval(((CMMotionManager *)self).accelerometerUpdateInterval);
    state.accelerometerTimer = VMTimer(interval, ^{
        CMAccelerometerData *data = VMCurrentAccelerometerData();
        if (data) [queue addOperationWithBlock:^{ handler(data, nil); }];
    });
}

static void VMStartGyroUpdates(id self, SEL _cmd, NSOperationQueue *queue,
                               CMGyroHandler handler) {
    VMManagerState *state = VMState(self);
    state.gyroActive = YES;
    double interval = VMClampInterval(((CMMotionManager *)self).gyroUpdateInterval);
    state.gyroTimer = VMTimer(interval, ^{
        CMGyroData *data = VMCurrentGyroData();
        if (data) [queue addOperationWithBlock:^{ handler(data, nil); }];
    });
}

static void VMStartDeviceMotionUpdates(id self, SEL _cmd, NSOperationQueue *queue,
                                       CMDeviceMotionHandler handler) {
    VMLog(@"[VirtualMotion] app subscribed to device-motion updates");
    VMManagerState *state = VMState(self);
    state.deviceMotionActive = YES;
    double interval = VMClampInterval(((CMMotionManager *)self).deviceMotionUpdateInterval);
    state.deviceMotionTimer = VMTimer(interval, ^{
        CMDeviceMotion *motion = VMCurrentDeviceMotion();
        if (motion) [queue addOperationWithBlock:^{ handler(motion, nil); }];
    });
}

/// The reference-frame variant funnels into the same stream: every frame we
/// could offer is the identity attitude anyway.
static void VMStartDeviceMotionUpdatesWithFrame(id self, SEL _cmd, CMAttitudeReferenceFrame frame,
                                                NSOperationQueue *queue,
                                                CMDeviceMotionHandler handler) {
    VMStartDeviceMotionUpdates(self, _cmd, queue, handler);
}

static void VMStopAccelerometerUpdates(id self, SEL _cmd) {
    VMManagerState *state = VMState(self);
    state.accelerometerActive = NO;
    if (state.accelerometerTimer) dispatch_source_cancel(state.accelerometerTimer);
    state.accelerometerTimer = nil;
}

static void VMStopGyroUpdates(id self, SEL _cmd) {
    VMManagerState *state = VMState(self);
    state.gyroActive = NO;
    if (state.gyroTimer) dispatch_source_cancel(state.gyroTimer);
    state.gyroTimer = nil;
}

static void VMStopDeviceMotionUpdates(id self, SEL _cmd) {
    VMManagerState *state = VMState(self);
    state.deviceMotionActive = NO;
    if (state.deviceMotionTimer) dispatch_source_cancel(state.deviceMotionTimer);
    state.deviceMotionTimer = nil;
}

#pragma mark - Install

static void VMInstallActivityHooks(void) {
    Class cls = objc_getClass("CMMotionActivityManager");
    if (!cls) return;
    VMReplaceClassMethod(cls, @selector(isActivityAvailable), (IMP)VMActivityAvailable);
    VMReplaceClassMethod(cls, @selector(authorizationStatus), (IMP)VMMotionAuthorized);
    VMReplace(cls, @selector(startActivityUpdatesToQueue:withHandler:),
              (IMP)VMStartActivityUpdates);
    VMReplace(cls, @selector(stopActivityUpdates), (IMP)VMStopActivityUpdates);
    VMReplace(cls, @selector(queryActivityStartingFromDate:toDate:toQueue:withHandler:),
              (IMP)VMQueryActivity);
    VMLog(@"[VirtualMotion] activity hooks installed");
}

static void VMInstallPedometerHooks(void) {
    Class cls = objc_getClass("CMPedometer");
    if (!cls) return;
    VMReplaceClassMethod(cls, @selector(isStepCountingAvailable), (IMP)VMPedometerYes);
    VMReplaceClassMethod(cls, @selector(isDistanceAvailable), (IMP)VMPedometerYes);
    VMReplaceClassMethod(cls, @selector(isPaceAvailable), (IMP)VMPedometerYes);
    VMReplaceClassMethod(cls, @selector(isCadenceAvailable), (IMP)VMPedometerYes);
    VMReplaceClassMethod(cls, @selector(isFloorCountingAvailable), (IMP)VMPedometerNo);
    VMReplaceClassMethod(cls, @selector(authorizationStatus), (IMP)VMMotionAuthorized);
    VMReplace(cls, @selector(startPedometerUpdatesFromDate:withHandler:),
              (IMP)VMStartPedometerUpdates);
    VMReplace(cls, @selector(stopPedometerUpdates), (IMP)VMStopPedometerUpdates);
    VMReplace(cls, @selector(queryPedometerDataFromDate:toDate:withHandler:),
              (IMP)VMQueryPedometer);
    VMLog(@"[VirtualMotion] pedometer hooks installed");
}

static void VMInstallManagerHooks(VMFactoryHealth health) {
    Class cls = objc_getClass("CMMotionManager");
    if (!cls) return;

    if (health.accelerometer) {
        VMReplace(cls, @selector(isAccelerometerAvailable), (IMP)VMManagerYes);
        VMReplace(cls, @selector(isAccelerometerActive), (IMP)VMAccelerometerActive);
        VMReplace(cls, @selector(accelerometerData), (IMP)VMAccelerometerDataProperty);
        VMReplace(cls, @selector(startAccelerometerUpdates), (IMP)VMStartAccelerometerPull);
        VMReplace(cls, @selector(startAccelerometerUpdatesToQueue:withHandler:),
                  (IMP)VMStartAccelerometerUpdates);
        VMReplace(cls, @selector(stopAccelerometerUpdates), (IMP)VMStopAccelerometerUpdates);

        VMReplace(cls, @selector(isGyroAvailable), (IMP)VMManagerYes);
        VMReplace(cls, @selector(isGyroActive), (IMP)VMGyroActive);
        VMReplace(cls, @selector(gyroData), (IMP)VMGyroDataProperty);
        VMReplace(cls, @selector(startGyroUpdates), (IMP)VMStartGyroPull);
        VMReplace(cls, @selector(startGyroUpdatesToQueue:withHandler:), (IMP)VMStartGyroUpdates);
        VMReplace(cls, @selector(stopGyroUpdates), (IMP)VMStopGyroUpdates);
    }

    if (health.deviceMotion) {
        VMReplace(cls, @selector(isDeviceMotionAvailable), (IMP)VMManagerYes);
        VMReplace(cls, @selector(isDeviceMotionActive), (IMP)VMDeviceMotionActive);
        VMReplace(cls, @selector(deviceMotion), (IMP)VMDeviceMotionProperty);
        VMReplace(cls, @selector(startDeviceMotionUpdates), (IMP)VMStartDeviceMotionPull);
        VMReplace(cls, @selector(startDeviceMotionUpdatesToQueue:withHandler:),
                  (IMP)VMStartDeviceMotionUpdates);
        VMReplace(cls, @selector(startDeviceMotionUpdatesUsingReferenceFrame:toQueue:withHandler:),
                  (IMP)VMStartDeviceMotionUpdatesWithFrame);
        VMReplace(cls, @selector(stopDeviceMotionUpdates), (IMP)VMStopDeviceMotionUpdates);
    }

    // Magnetometer stays off — see VMManagerNo.
    VMReplace(cls, @selector(isMagnetometerAvailable), (IMP)VMManagerNo);
    VMReplace(cls, @selector(magnetometerData), (IMP)VMMagnetometerDataProperty);

    VMLog(@"[VirtualMotion] motion-manager hooks installed (accelerometer=%d deviceMotion=%d)",
          health.accelerometer, health.deviceMotion);
}

__attribute__((constructor)) static void VirtualMotionInit(void) {
    VMFactoryHealth health = VMFactorySelfCheck();
    if (!health.activity && !health.pedometer && !health.accelerometer && !health.deviceMotion) {
        VMLog(@"[VirtualMotion] self-check failed on every surface — installing nothing. "
              @"CoreMotion's private layout has probably moved; apps will see the "
              @"platform's own 'unavailable' rather than fabricated data.");
        return;
    }
    if (health.activity) VMInstallActivityHooks();
    if (health.pedometer) VMInstallPedometerHooks();
    if (health.accelerometer || health.deviceMotion) VMInstallManagerHooks(health);
    if (!health.activity || !health.pedometer || !health.accelerometer || !health.deviceMotion) {
        VMLog(@"[VirtualMotion] partial install — activity=%d pedometer=%d accelerometer=%d "
              @"deviceMotion=%d", health.activity, health.pedometer, health.accelerometer,
              health.deviceMotion);
    }
}
