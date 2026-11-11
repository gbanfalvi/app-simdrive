import CoreGraphics
import SimDriveNative

/// Maps points of a screenshot to the digitizer's unit coordinates, which follow the panel's native orientation.
/// `simctl` screenshots follow the interface, so a screenshot whose aspect differs from the panel's is rotated.
struct ScreenMapping: Equatable, Sendable {
    private static let midpoint = 0.5

    let isRotated: Bool
    /// The device orientation the screenshot's interface matches.
    let orientation: DeviceOrientation

    /// A screenshot of a panel, rotated by the interface's orientation at capture, or by the device's when unknown.
    init(screenshot: ScreenRecord, panelIsLandscape: Bool, deviceOrientation: DeviceOrientation) {
        self.init(isRotated: screenshot.full.isLandscape != panelIsLandscape,
                  orientation: screenshot.interfaceOrientation?.deviceOrientation ?? deviceOrientation)
    }

    init(isRotated: Bool, orientation: DeviceOrientation) {
        self.isRotated = isRotated
        self.orientation = orientation
    }

    /// `point` is in unit coordinates of the screenshot, from its top-left corner.
    func digitizerPoint(_ point: CGPoint) -> CGPoint {
        let (x, y) = (point.x, point.y)
        if isRotated {
            // A rotated screen whose device still reads portrait, such as the Duo's inner panel, turns like landscapeRight.
            return orientation == .landscapeLeft ? CGPoint(x: 1 - y, y: x) : CGPoint(x: y, y: 1 - x)
        }
        return orientation == .portraitUpsideDown ? CGPoint(x: 1 - x, y: 1 - y) : point
    }

    /// The panel edge that a screenshot edge lies on.
    func digitizerEdge(_ edge: ScreenEdge) -> ScreenEdge {
        let point = switch edge {
        case .top: CGPoint(x: Self.midpoint, y: 0)
        case .bottom: CGPoint(x: Self.midpoint, y: 1)
        case .left: CGPoint(x: 0, y: Self.midpoint)
        case .right: CGPoint(x: 1, y: Self.midpoint)
        }
        let mapped = digitizerPoint(point)
        if mapped.y == 0 { return .top }
        if mapped.y == 1 { return .bottom }
        return mapped.x == 0 ? .left : .right
    }
}
