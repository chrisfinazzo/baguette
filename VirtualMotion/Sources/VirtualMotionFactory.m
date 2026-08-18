#import "VirtualMotionFactory.h"
#import <objc/runtime.h>
#import <objc/message.h>

// ---------------------------------------------------------------------------
// Measured ABI notes. Each line is a probe result, not an assumption.
//
// CMMotionActivity
//   -initWithMotionActivity:  takes `const CLMotionActivity *` — a real
//   pointer (the encoding is `r^{CLMotionActivity=…}`), unlike the structs
//   below. Its 136-byte size is derived at runtime from the gap between the
//   `fState` and `fEndTime` ivars rather than hardcoded.
//   Field offsets within it: type +0, confidence +4, timestamp +40,
//   startTime +80 (seconds since the 2001 reference date, not unix epoch).
//   Building one by poking ivars after a bare +alloc *looks* fine — the
//   boolean getters read back correctly — then crashes in -description,
//   -copy, -timestamp and NSKeyedArchiver, because CMLogItem's own state is
//   never initialised. Going through the designated initialiser is what
//   makes those safe.
//
// CMAccelerometerData / CMGyroData
//   Their `{fff}` struct is 12 bytes, so arm64 passes it **by value in
//   registers**. Handing over a pointer reads zeros *and* displaces the
//   trailing double timestamp. Declare the struct; let the compiler follow
//   the ABI.
//   CMGyroData's initialiser takes **degrees** per second: feeding 0.25
//   reads back as 0.004 ≈ 0.25 / 57.2958. CMDeviceMotion's rotationRate,
//   confusingly, is already radians.
//
// CMDeviceMotion
//   -initWithDeviceMotion:internal:timestamp: takes both structs by value.
//   Quaternion order in the struct is **w,x,y,z**, while the public
//   CMQuaternion is x,y,z,w.
//   Triple at +32 is userAcceleration; +44 is rotationRate; the triple at
//   +56 has no observable effect. `gravity` is **derived from attitude** and
//   cannot be set directly (identity attitude → (0,0,-1); 90° about x →
//   (0,-1,0)), so a level attitude is what makes gravity look like a phone
//   held upright.
//   The `timestamp:` argument is ignored. The timestamp actually lives in
//   CMLogItemInternal.fTimestamp, reachable through CMLogItem's
//   `_internalLogItem` ivar.
// ---------------------------------------------------------------------------

typedef struct { float x, y, z; } VMFloat3;
typedef struct { double w, x, y, z; } VMQuat;

typedef struct {
    VMQuat attitude;         //  0
    VMFloat3 userAccel;      // 32
    VMFloat3 rotationRate;   // 44
    VMFloat3 unused;         // 56 — no observable effect
    int32_t i0;              // 68
    bool b0, b1, b2;         // 72
    float f0;                // 76
    bool b3, b4;             // 80
    int32_t i1;              // 84
} VMMotionState;             // 88 bytes

typedef struct { float f0; VMFloat3 triple; float f1, f2; } VMMotionInternal;  // 24 bytes

static const double kDegreesPerRadian = 57.29577951308232;

/// Stamps any `CMLogItem` subclass, for the classes whose initialiser drops
/// the timestamp on the floor.
static void VMStamp(id logItem, double timestamp) {
    static Ivar holder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        holder = class_getInstanceVariable(CMLogItem.class, "_internalLogItem");
    });
    if (!holder || !logItem) return;
    id internal = object_getIvar(logItem, holder);
    if (!internal) return;
    @try {
        [internal setValue:@(timestamp) forKey:@"fTimestamp"];
    } @catch (NSException *e) {
        // Cosmetic if it fails; never worth taking the app down.
    }
}

#pragma mark - CMMotionActivity

/// Size of the `CLMotionActivity` struct, derived from the ivar layout so a
/// future field addition doesn't silently truncate it.
/// The furthest byte `VMMakeActivity` writes: the `startTime` double at +80.
/// If a future runtime reorders or shrinks the `fState`…`fEndTime` gap, a
/// smaller buffer would let those writes run off the end of the heap
/// allocation, so the derived size is rejected rather than trusted.
static const size_t kVMActivityMinStateSize = 88;

static size_t VMActivityStateSize(void) {
    Class cls = objc_getClass("CMMotionActivity");
    Ivar state = class_getInstanceVariable(cls, "fState");
    Ivar endTime = class_getInstanceVariable(cls, "fEndTime");
    if (!state || !endTime) return 0;
    ptrdiff_t gap = ivar_getOffset(endTime) - ivar_getOffset(state);
    if (gap < (ptrdiff_t)kVMActivityMinStateSize) return 0;
    return (size_t)gap;
}

CMMotionActivity *VMMakeActivity(int32_t activityType, int32_t confidence, NSDate *startDate) {
    size_t size = VMActivityStateSize();
    if (size == 0) return nil;
    void *buf = calloc(1, size);
    if (!buf) return nil;
    double startTime = startDate.timeIntervalSinceReferenceDate;
    double uptime = NSProcessInfo.processInfo.systemUptime;
    memcpy((char *)buf + 0, &activityType, sizeof(int32_t));
    memcpy((char *)buf + 4, &confidence, sizeof(int32_t));
    memcpy((char *)buf + 40, &uptime, sizeof(double));
    memcpy((char *)buf + 80, &startTime, sizeof(double));
    CMMotionActivity *activity = ((id (*)(id, SEL, const void *))objc_msgSend)(
        [objc_getClass("CMMotionActivity") alloc],
        sel_getUid("initWithMotionActivity:"), buf);
    free(buf);
    return activity;
}

#pragma mark - CMPedometerData

CMPedometerData *VMMakePedometerData(NSDate *start, NSDate *end, long steps,
                                     double metres, double cadenceHz, double speed) {
    id data = [[objc_getClass("CMPedometerData") alloc] init];
    if (!data) return nil;
    // Plain NSObject with object-typed ivars, so KVC sets them directly and
    // handles the retain — no designated-initialiser dance needed, and no
    // uninitialised superclass to trip over.
    @try {
        [data setValue:start forKey:@"fStartDate"];
        [data setValue:end forKey:@"fEndDate"];
        [data setValue:@(steps) forKey:@"fNumberOfSteps"];
        [data setValue:@(metres) forKey:@"fDistance"];
        // Cadence and pace are step measures, so both are gated on this kind
        // actually taking steps. Reporting a pace while cycling — with zero
        // steps and zero distance behind it — would hand an app a figure
        // nothing else it reads agrees with.
        if (cadenceHz > 0) {
            [data setValue:@(cadenceHz) forKey:@"fCurrentCadence"];
            // Pace is seconds per metre, the reciprocal of speed.
            if (speed > 0) [data setValue:@(1.0 / speed) forKey:@"fCurrentPace"];
        }
    } @catch (NSException *e) {
        return nil;
    }
    return data;
}

#pragma mark - CMMotionManager samples

CMAccelerometerData *VMMakeAccelerometerData(double x, double y, double z, double timestamp) {
    VMFloat3 xyz = {(float)x, (float)y, (float)z};
    return ((id (*)(id, SEL, VMFloat3, double))objc_msgSend)(
        [objc_getClass("CMAccelerometerData") alloc],
        sel_getUid("initWithAcceleration:andTimestamp:"), xyz, timestamp);
}

CMGyroData *VMMakeGyroData(double x, double y, double z, double timestamp) {
    // Degrees in, radians out of the public property.
    VMFloat3 xyz = {(float)(x * kDegreesPerRadian),
                    (float)(y * kDegreesPerRadian),
                    (float)(z * kDegreesPerRadian)};
    return ((id (*)(id, SEL, VMFloat3, double))objc_msgSend)(
        [objc_getClass("CMGyroData") alloc],
        sel_getUid("initWithRotationRate:andTimestamp:"), xyz, timestamp);
}

CMDeviceMotion *VMMakeDeviceMotion(double ax, double ay, double az,
                                   double rx, double ry, double rz, double timestamp) {
    VMMotionState state = {0};
    // Identity attitude — a phone held level and upright, which is also what
    // makes the derived gravity read (0, 0, -1).
    state.attitude = (VMQuat){.w = 1, .x = 0, .y = 0, .z = 0};
    state.userAccel = (VMFloat3){(float)ax, (float)ay, (float)az};
    state.rotationRate = (VMFloat3){(float)rx, (float)ry, (float)rz};
    VMMotionInternal internal = {0};
    CMDeviceMotion *motion = ((id (*)(id, SEL, VMMotionState, VMMotionInternal, double))objc_msgSend)(
        [objc_getClass("CMDeviceMotion") alloc],
        sel_getUid("initWithDeviceMotion:internal:timestamp:"), state, internal, timestamp);
    VMStamp(motion, timestamp);
    return motion;
}

#pragma mark - Self-check

VMFactoryHealth VMFactorySelfCheck(void) {
    VMFactoryHealth health = {0};

    // Activity: 4 is the measured `walking` type. Reading the flag back
    // proves both the offsets and the enum value; touching -description
    // proves the object is whole enough to log.
    CMMotionActivity *activity = VMMakeActivity(4, 2, NSDate.date);
    if (activity && activity.walking && activity.confidence == 2
        && activity.startDate != nil && [activity description] != nil) {
        health.activity = YES;
    }

    CMPedometerData *pedometer = VMMakePedometerData(
        [NSDate dateWithTimeIntervalSinceNow:-60], NSDate.date, 812, 610.5, 1.87, 1.5);
    if (pedometer && pedometer.numberOfSteps.longValue == 812
        && fabs(pedometer.distance.doubleValue - 610.5) < 0.001) {
        health.pedometer = YES;
    }

    CMAccelerometerData *accel = VMMakeAccelerometerData(0.25, -0.5, 0.75, 42.5);
    CMGyroData *gyro = VMMakeGyroData(1.0, 0, 0, 42.5);
    if (accel && fabs(accel.acceleration.x - 0.25) < 0.001
        && fabs(accel.acceleration.z - 0.75) < 0.001
        && fabs(accel.timestamp - 42.5) < 0.001
        && gyro && fabs(gyro.rotationRate.x - 1.0) < 0.01) {
        health.accelerometer = YES;
    }

    CMDeviceMotion *motion = VMMakeDeviceMotion(0.1, 0.2, 0.3, 1.5, 0, 0, 99.5);
    if (motion && fabs(motion.userAcceleration.x - 0.1) < 0.001
        && fabs(motion.rotationRate.x - 1.5) < 0.001
        && fabs(motion.gravity.z + 1.0) < 0.01
        && fabs(motion.timestamp - 99.5) < 0.001) {
        health.deviceMotion = YES;
    }

    return health;
}
