import Foundation
import IOSurface
import Mockable

/// A loaded 3D device scene whose screen can be updated and rendered
/// repeatedly. The scene owns expensive model/renderer state for one live
/// connection.
@Mockable
protocol DeviceScene: AnyObject, Sendable {
    /// Replace the device screen with the supplied simulator surface and
    /// return one JPEG of the composed 3D scene.
    func render(screen: IOSurface) throws -> Data
}
