// VirtualMotionIntent — reads the motion intent baguette publishes and
// integrates it into the numbers CoreMotion consumers expect.
//
// The host writes an *intent* ("running at 3.6 m/s since T, with N steps
// already accrued"), not a stream of samples: a pedometer accumulates
// monotonically and CMMotionManager delivers at up to 100 Hz, so neither
// can cross a file boundary sample-by-sample. Every judgement call —
// stride length, cadence, gait amplitude — is resolved host-side in
// `MotionProfile` and arrives pre-computed, so this file only does
// arithmetic.

#import <Foundation/Foundation.h>

/// Where the host publishes. Same shared-`/tmp` convention the camera uses
/// for `/tmp/SimCam.bgra`.
extern NSString *const VMIntentPath;

typedef struct {
    /// NO when nothing has been published yet (or the file is unreadable),
    /// in which case every surface reports "no motion" rather than guessing.
    BOOL valid;
    /// Raw `CLMotionActivity.type` — resolved host-side, copied verbatim.
    int32_t activityType;
    /// Raw `CMMotionActivityConfidence`.
    int32_t confidence;
    double speed;          // m/s
    double startedAt;      // unix epoch seconds; host and guest share a clock
    long stepsBefore;      // steps accrued by earlier legs
    double distanceBefore; // metres accrued by earlier legs
    double cadenceHz;      // steps per second; 0 means this kind takes no steps
    double gaitAmplitude;  // peak synthetic acceleration, in g
    double strideMetres;   // 0 means this kind takes no steps
} VMIntent;

/// The current intent, re-read when the file changes. Cheap enough to call
/// per sample: the file is stat'ed at most every 100 ms and parsed only when
/// its mtime moves.
VMIntent VMIntentCurrent(void);

/// Steps accrued in total by `now` (unix epoch) — the earlier legs plus the
/// whole steps taken in the leg currently running.
long VMIntentSteps(VMIntent intent, double now);

/// Metres accrued in total by `now`. Derived from whole steps × stride so it
/// can never disagree with the step count reported alongside it.
double VMIntentDistance(VMIntent intent, double now);

/// The oscillation frequency to synthesise motion at, in Hz. Footfall
/// cadence while walking or running; a fixed road/vehicle vibration
/// otherwise, so a car ride isn't perfectly still.
double VMIntentShakeHz(VMIntent intent);
