import CoreGraphics

/// Where the frontmost app sits on the iPhone Duo's inner screen: one half, or both.
enum SplitLayout: String, CaseIterable, Sendable {
    case left, right, full

    var isHalf: Bool { self != .full }
}

/// A drag of the app's home indicator from one layout to another, in fractions of the inner screen in landscape.
/// Repeated points hold, and the last point lifts the touch, so the guest reads a drop instead of a flick.
struct SplitGesture: Equatable {
    let path: [CGPoint]
    let duration: Duration

    private static let toRightHalf = SplitGesture(path: [
        CGPoint(x: 0.5, y: 0.97), CGPoint(x: 0.70, y: 0.89), CGPoint(x: 0.82, y: 0.895), CGPoint(x: 0.82, y: 0.895),
        CGPoint(x: 0.82, y: 0.86),
    ], duration: .milliseconds(1000))

    /// Lifting, then settling at the middle, before letting go keeps the full screen without opening the app switcher.
    private static let rightHalfToFull = SplitGesture(path: [
        CGPoint(x: 0.75, y: 0.97), CGPoint(x: 0.55, y: 0.92), CGPoint(x: 0.5, y: 0.925), CGPoint(x: 0.5, y: 0.925),
        CGPoint(x: 0.5, y: 0.905), CGPoint(x: 0.5, y: 0.915),
    ], duration: .milliseconds(1000))

    private static let rightHalfToLeftHalf = SplitGesture(path: [
        CGPoint(x: 0.75, y: 0.97), CGPoint(x: 0.70, y: 0.945), CGPoint(x: 0.40, y: 0.89), CGPoint(x: 0.18, y: 0.895),
        CGPoint(x: 0.18, y: 0.895), CGPoint(x: 0.18, y: 0.86),
    ], duration: .milliseconds(1000))

    /// Nil when the app is already in the layout.
    static func moving(from current: SplitLayout, to target: SplitLayout) -> SplitGesture? {
        switch (current, target) {
        case (.full, .right): toRightHalf
        case (.full, .left): toRightHalf.mirrored
        case (.right, .full): rightHalfToFull
        case (.left, .full): rightHalfToFull.mirrored
        case (.right, .left): rightHalfToLeftHalf
        case (.left, .right): rightHalfToLeftHalf.mirrored
        case (.full, .full), (.left, .left), (.right, .right): nil
        }
    }

    private var mirrored: SplitGesture {
        SplitGesture(path: path.map { CGPoint(x: 1 - $0.x, y: $0.y) }, duration: duration)
    }
}
