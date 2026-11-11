import CoreGraphics

/// A device orientation, by CoreDevice `DeviceOrientation` raw value.
package enum DeviceOrientation: String, Codable, CaseIterable, Sendable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

    private static let aliases: [String: DeviceOrientation] = [
        "landscape-left": .landscapeLeft, "landscape-right": .landscapeRight, "upside-down": .portraitUpsideDown,
    ]

    package init?(name: String) {
        guard let orientation = DeviceOrientation(rawValue: name) ?? Self.aliases[name.lowercased()] else { return nil }
        self = orientation
    }
}

package enum ScreenEdge: String, CaseIterable, Sendable { case top, bottom, left, right }

/// Maps points of a screenshot to the digitizer's unit coordinates, which follow the panel's native orientation.
/// `simctl` screenshots follow the interface, so a screenshot whose aspect differs from the panel's is rotated.
package struct ScreenMapping: Equatable, Sendable {
    private static let midpoint = 0.5

    package let isRotated: Bool
    package let orientation: DeviceOrientation

    package init(isRotated: Bool, orientation: DeviceOrientation) {
        self.isRotated = isRotated
        self.orientation = orientation
    }

    /// `point` is in unit coordinates of the screenshot, from its top-left corner.
    package func digitizerPoint(_ point: CGPoint) -> CGPoint {
        let (x, y) = (point.x, point.y)
        if isRotated {
            // A rotated screen whose device still reads portrait, such as the Duo's inner panel, turns like landscapeRight.
            return orientation == .landscapeLeft ? CGPoint(x: 1 - y, y: x) : CGPoint(x: y, y: 1 - x)
        }
        return orientation == .portraitUpsideDown ? CGPoint(x: 1 - x, y: 1 - y) : point
    }

    /// The panel edge that a screenshot edge lies on.
    package func digitizerEdge(_ edge: ScreenEdge) -> ScreenEdge {
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
