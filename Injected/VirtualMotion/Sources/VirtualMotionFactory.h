// VirtualMotionFactory — builds real CoreMotion objects with values of our
// choosing.
//
// CoreMotion's data classes have no public initialisers, so each is built
// through its private designated initialiser. Every ABI detail here was
// measured against booted iOS 26.5 / 27.0 runtimes, not read from a header;
// the notes in the .m record what each probe showed, because the failure mode
// for guessing is an app that crashes or reads silent zeros.
//
// `VMFactorySelfCheck` builds one of each and verifies the values read back
// through the public API. Callers must run it before installing hooks: if a
// future iOS moves any of this, an app is better served by the platform's
// honest "unavailable" than by our garbage.

#import <Foundation/Foundation.h>
#import <CoreMotion/CoreMotion.h>

/// Which surfaces verified successfully — hook only these.
typedef struct {
    BOOL activity;
    BOOL pedometer;
    BOOL accelerometer;   // covers CMAccelerometerData + CMGyroData
    BOOL deviceMotion;
} VMFactoryHealth;

VMFactoryHealth VMFactorySelfCheck(void);

/// A `CMMotionActivity` reporting `activityType` (a raw
/// `CLMotionActivity.type`) with `confidence`, starting at `startDate`.
CMMotionActivity *VMMakeActivity(int32_t activityType, int32_t confidence, NSDate *startDate);

/// A `CMPedometerData` for the window `start`…`end`.
CMPedometerData *VMMakePedometerData(NSDate *start, NSDate *end, long steps,
                                     double metres, double cadenceHz, double speed);

/// Raw accelerometer sample, in g, gravity included.
CMAccelerometerData *VMMakeAccelerometerData(double x, double y, double z, double timestamp);

/// Gyro sample, in **radians** per second — converted internally to the
/// degrees the private initialiser expects.
CMGyroData *VMMakeGyroData(double x, double y, double z, double timestamp);

/// Device motion with a level attitude, `userAcceleration` in g (gravity
/// excluded) and `rotationRate` in radians per second.
CMDeviceMotion *VMMakeDeviceMotion(double ax, double ay, double az,
                                   double rx, double ry, double rz, double timestamp);
