import Foundation
import IOSurface
import Mockable

/// A loaded 3D device scene whose screen can be updated and rendered
/// repeatedly. The scene owns expensive model/renderer state for one live
/// connection.
@Mockable
protocol DeviceScene: AnyObject, Sendable {
    /// Replace the device screen with the supplied simulator surface and
    /// return the composed 3D scene as a BGRA surface. Keeping the result
    /// unencoded lets any existing stream codec consume it.
    func render(screen: IOSurface) throws -> IOSurface

    /// Current projection of the model's display into output pixels.
    var projection: DeviceScreenProjection { get }

    /// Mutate camera state without reloading the model or reconnecting.
    @discardableResult
    func update(camera: Device3DCamera) -> DeviceScreenProjection
}
