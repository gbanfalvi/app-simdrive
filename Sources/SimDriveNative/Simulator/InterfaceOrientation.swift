/// A screen's interface orientation, which `simctl` rotates screenshots by. It can differ from the device's orientation
/// when the foreground app does not support that one.
package enum InterfaceOrientation: String, Codable, CaseIterable, Sendable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

    /// The interface counter-rotates the device, so UIKit's landscape interface and device names swap.
    package var deviceOrientation: DeviceOrientation {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        }
    }

    /// CoreSimulator's `uiOrientation`, named as `simctl io enumerate` labels it; nil for 0, its `Ambiguous`.
    init?(screenValue: UInt32) {
        switch screenValue {
        case 1: self = .portrait
        case 2: self = .portraitUpsideDown
        case 3: self = .landscapeLeft
        case 4: self = .landscapeRight
        default: return nil
        }
    }
}
