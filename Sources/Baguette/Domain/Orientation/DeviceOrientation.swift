import Foundation

/// A booted simulator's interface orientation. The four cases mirror
/// `UIDeviceOrientation` and use the same raw values on the wire — the
/// 4-byte payload of a `GSEventTypeDeviceOrientationChanged` mach
/// message at offset 0x4C is exactly this number.
public enum DeviceOrientation: UInt32, Sendable, CaseIterable, Equatable {
    case portrait              = 1
    case portraitUpsideDown    = 2
    case landscapeRight        = 3   // Home button on the right (rotated 90° CW)
    case landscapeLeft         = 4   // Home button on the left  (rotated 90° CCW)
}
