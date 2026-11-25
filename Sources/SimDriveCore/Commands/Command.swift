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
    /// Taps the element a selector names, waiting up to `timeout` for it to appear.
    case tapElement(ElementSelector, timeout: Duration)
    /// Drags through two or more points.
    case swipe(path: [ScreenPoint], duration: Duration, edge: ScreenEdge?, display: DisplaySelector)
    /// Repeats a swipe until the element a selector names is on screen, at most `maxSwipes` times.
    case swipeUntil(path: [ScreenPoint], duration: Duration, selector: ElementSelector, maxSwipes: Int)
    /// Two fingers spread to `scale` times their distance around `center`, or close below 1.
    case pinch(center: ScreenPoint, scale: Double, duration: Duration, display: DisplaySelector)
    /// Two fingers turn around `center`, clockwise for positive degrees.
    case rotate(center: ScreenPoint, degrees: Double, duration: Duration, display: DisplaySelector)
    /// `legacy` presses through `remote.hid.button` and `IndigoButtonEvent`, which Xcode 27.3 removed.
    case button(HardwareButton, count: Int, hold: Duration, legacy: Bool)
    /// Sets the posture, or reads the hinge without one.
    case posture(DevicePosture?)
    /// Moves the inner screen's app to a layout; `from` overrides the one simdrive last set.
    case split(SplitLayout, from: SplitLayout?)
    /// Sets the orientation, or reads it without one.
    case orientation(DeviceOrientation?)
    /// Replaces the pasteboard with text, or reads it without any.
    case pasteboard(text: String?)
    case screenshot(path: String, display: DisplaySelector, maxDimension: Int)
    /// Reads the frontmost app's accessibility hierarchy, or the element at a point.
    /// `covered` marks elements a tap would not reach, as under an alert; `app` reads that app instead of the frontmost one.
    case tree(at: ScreenPoint?, detail: TreeDetail, covered: Bool = false, app: String? = nil)
    /// Lists every setting without one, reads it without a value, or changes it.
    case setting(Setting?, value: JSONValue?)
    case launch(bundleID: String, arguments: [String])
    /// Installs an `.app` or `.ipa`.
    case install(path: String)
    case uninstall(bundleID: String)
    /// Opens a URL, such as a deep link, in the app that handles it.
    case openURL(String)
    /// Sends a simulated remote push notification to an app.
    case push(bundleID: String, payload: PushPayload)
    /// Grants, revokes or resets an app's access to a privacy service, such as photos, without its alert.
    case privacy(PrivacyAction, service: String, bundleID: String?)
    /// Overrides the status bar's values, or with nil clears every override.
    case statusBar(StatusBarOverride?)
    case wait(milliseconds: Int)
    /// Waits up to `timeout` until the element a selector names is on screen, or, when `gone`, until it is not.
    case waitForElement(ElementSelector, gone: Bool, timeout: Duration)
    case logs(LogQuery)
    /// With `attachesLogs`, each step's result lists the entries logged while it ran.
    case run(steps: [Step], attachesLogs: Bool)
    /// Shakes the device, as Simulator's Device > Shake does.
    case shake
    /// Sends running apps a memory warning, as Simulator's Debug > Simulate Memory Warning does.
    case memoryWarning
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

/// A command of `run`, with the arguments that errors quote.
struct Step: Equatable, Sendable {
    let arguments: [String]
    let command: Command
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
