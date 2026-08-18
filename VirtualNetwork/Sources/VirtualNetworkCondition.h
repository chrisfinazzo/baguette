// VirtualNetworkCondition — reads the network condition baguette publishes
// and hands it to the protocol as plain numbers.
//
// Every judgement call is resolved host-side in `NetworkCondition` /
// `NetworkSchedule` and arrives pre-computed — including how many bytes may
// be released per tick and how long a tick is — so this side only compares
// and subtracts. Same division of labour the motion dylib has.

#import <Foundation/Foundation.h>

/// Where the host publishes. Same shared-`/tmp` convention the camera uses
/// for `/tmp/SimCam.bgra` and motion for `/tmp/BaguetteMotion.json`.
extern NSString *const VNConditionPath;

typedef struct {
    /// NO when nothing has been published yet, or the file is unreadable.
    BOOL valid;
    /// NO when the published condition changes nothing. Requests are then
    /// left completely alone — not intercepted and re-issued at full speed,
    /// but never touched at all, so a cleared condition costs an app
    /// exactly nothing.
    BOOL conditioning;
    /// Milliseconds a request waits before its first byte. Whole round
    /// trip, already doubled from any one-way figure host-side.
    double latencyMs;
    /// Percentage of requests failed outright, 0…100.
    double lossPercent;
    /// The device reports no connection at all.
    BOOL offline;
    /// Bytes released per tick. 0 means unmetered — hand data straight on.
    long bytesPerTick;
    /// Milliseconds between ticks.
    double tickIntervalMs;
    /// Bumped every time the file changes, so a caller can tell "the same
    /// condition" from "a new one that happens to match".
    uint64_t generation;
} VNCondition;

/// The current condition, re-read when the file changes. Cheap enough to
/// call per request: the file is stat'ed at most every 100 ms and parsed
/// only when its mtime moves.
VNCondition VNConditionCurrent(void);

/// Diagnostics go to the unified log **only** — never NSLog.
///
/// This dylib is loaded into *every* process launched in the simulator
/// while conditioning is armed, including the short-lived `launchctl`
/// baguette spawns to read `DYLD_INSERT_LIBRARIES`. NSLog writes to stderr,
/// and the simulator's stdout/stderr channel carries leftovers between
/// spawned processes, so a banner printed here can come back as part of the
/// value baguette is trying to read. `InjectedDylibs.parsing` defends
/// against that too, but the dylib has no business writing to a host
/// process's streams in the first place. Read these with:
///   xcrun simctl spawn <udid> log stream --predicate 'subsystem == "com.baguette.network"'
void VNLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// `VNLog`, but at most one line per second per `key`.
///
/// A conditioned app makes hundreds of requests a minute and every one of
/// them is interesting exactly once. Throttling keeps the log readable
/// without going silent — silence is what makes "is this thing even
/// loaded?" unanswerable, which is the question the motion work proved you
/// always end up asking.
void VNLogThrottled(const char *key, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
