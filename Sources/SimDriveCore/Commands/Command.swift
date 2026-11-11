import CoreGraphics
import SimDriveNative

/// A point of a screen: fractions of the screenshot from its top-left corner, or pixels of the last screenshot's image.
enum ScreenPoint: Equatable, Sendable {
    case normalized(CGPoint)
    case pixels(CGPoint)

    private static let normalizedRange: ClosedRange<Double> = 0...1

    /// Values in 0...1 written with a decimal point are fractions; anything else is pixels.
    init?(x: String, y: String) {
        guard let xValue = Double(x), let yValue = Double(y), xValue >= 0, yValue >= 0 else { return nil }
        let point = CGPoint(x: xValue, y: yValue)
        let isNormalized = Self.normalizedRange.contains(xValue) && Self.normalizedRange.contains(yValue)
            && (x.contains(".") || y.contains("."))
        self = isNormalized ? .normalized(point) : .pixels(point)
    }

    var usesPixels: Bool {
        if case .pixels = self { return true }
        return false
    }
}

enum Command: Equatable, Sendable {
    case key(name: String, modifiers: Set<KeyModifier>, count: Int)
    case type(text: String)
    case tap(ScreenPoint, display: DisplaySelector)
    case swipe(from: ScreenPoint, to: ScreenPoint, duration: Duration, edge: ScreenEdge?, display: DisplaySelector)
    case button(HardwareButton, count: Int, hold: Duration)
    /// Sets the posture, or reads the hinge without one.
    case posture(DevicePosture?)
    /// Sets the orientation, or reads it without one.
    case orientation(DeviceOrientation?)
    /// Replaces the pasteboard with text, or reads it without any.
    case pasteboard(text: String?)
    case screenshot(path: String, display: DisplaySelector, maxDimension: Int)
    case launch(bundleID: String, arguments: [String])
    case wait(milliseconds: Int)
    case run(steps: [[String]])
    case doctor
    case stop
    case serve

    /// Whether the command can be a step of `run`.
    var isStep: Bool {
        switch self {
        case .run, .stop, .serve: false
        default: true
        }
    }
}

extension DeviceOrientation {
    /// The command-line spelling, which results use too.
    var name: String {
        switch self {
        case .portrait: "portrait"
        case .portraitUpsideDown: "upside-down"
        case .landscapeLeft: "landscape-left"
        case .landscapeRight: "landscape-right"
        }
    }

    /// A command-line spelling or a CoreDevice raw value.
    init?(name: String) {
        let lowered = name.lowercased()
        guard let orientation = DeviceOrientation(rawValue: name) ?? Self.allCases.first(where: { $0.name == lowered }) else {
            return nil
        }
        self = orientation
    }
}
