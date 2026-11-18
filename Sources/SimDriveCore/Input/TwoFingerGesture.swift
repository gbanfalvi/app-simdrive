import CoreGraphics

/// Two fingers' paths around a center, as fractions of a screen, laid out in its pixels so its aspect does not skew them.
struct TwoFingerGesture: Equatable {
    /// The fingers' larger distance from the center, as a fraction of the screen's shorter side.
    private static let outerRadius: CGFloat = 0.3
    private static let rotationRadius: CGFloat = 0.2
    /// The largest turn between two points of a rotation's arc.
    private static let arcStep: CGFloat = 10
    private static let degreesPerTurn: CGFloat = 360

    let first: [CGPoint]
    let second: [CGPoint]

    /// Fingers on a horizontal line that spread to `scale` times their distance, or close to it below 1.
    static func pinch(around center: CGPoint, scale: CGFloat, screen size: CGSize) -> TwoFingerGesture {
        let outer = outerRadius * min(size.width, size.height)
        let radii = scale >= 1 ? [outer / scale, outer] : [outer, outer * scale]
        return TwoFingerGesture(radii.map { (radius: $0, degrees: 0) }, around: center, screen: size)
    }

    /// Fingers that turn by `degrees`, clockwise when positive.
    static func rotation(around center: CGPoint, degrees: CGFloat, screen size: CGSize) -> TwoFingerGesture {
        let radius = rotationRadius * min(size.width, size.height)
        let steps = max(1, Int((abs(degrees) / arcStep).rounded(.up)))
        let points = (0...steps).map { (radius: radius, degrees: degrees * CGFloat($0) / CGFloat(steps)) }
        return TwoFingerGesture(points, around: center, screen: size)
    }

    private init(first: [CGPoint], second: [CGPoint]) {
        self.first = first
        self.second = second
    }

    /// Each point puts the first finger at `radius` and `degrees` from the center, and the second opposite it.
    private init(_ points: [(radius: CGFloat, degrees: CGFloat)], around center: CGPoint, screen size: CGSize) {
        let origin = CGPoint(x: center.x * size.width, y: center.y * size.height)
        func finger(_ radius: CGFloat, _ degrees: CGFloat) -> CGPoint {
            let angle = degrees / Self.degreesPerTurn * 2 * .pi
            return CGPoint(x: (origin.x + radius * cos(angle)) / size.width, y: (origin.y + radius * sin(angle)) / size.height)
        }
        self.init(first: points.map { finger($0.radius, $0.degrees) },
                  second: points.map { finger($0.radius, $0.degrees + Self.degreesPerTurn / 2) })
    }
}
