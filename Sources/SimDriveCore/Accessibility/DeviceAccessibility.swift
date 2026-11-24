import CoreGraphics
import SimDriveNative

/// The frontmost app's accessibility hierarchy, placed in the screen fractions that `tap` takes.
@MainActor
final class DeviceAccessibility {
    private static let frontmostPollInterval: Duration = .milliseconds(100)
    /// A light tree read takes tens of milliseconds, so this keeps waits responsive without reading continuously.
    private static let elementPollInterval: Duration = .milliseconds(200)
    /// A split app's window is about 0.49 of the screen wide, and a full one 1.
    private static let halfWidthLimit = 0.75

    private let device: SimulatorDevice
    private let screens: Screens
    private let split: SplitState
    private let accessibility: LazyCapability<SimulatorAccessibility>

    init(device: SimulatorDevice, screens: Screens, split: SplitState) {
        self.device = device
        self.screens = screens
        self.split = split
        accessibility = LazyCapability { try await SimulatorAccessibility.open(device: device) }
    }

    /// Starts the guest's accessibility server, whose first read takes about 10 s, without waiting for it.
    func prepare() {
        Task { [accessibility] in _ = try? await accessibility.value()?.application() }
    }

    func tree(detail: TreeDetail) async throws -> JSONValue {
        let (snapshot, screen, layout) = try await read(detail: detail)
        let app = snapshot.application.json
        let display = JSONValue(screen.display?.index)
        switch detail {
        case .light: return ["app": app, "display": display, "elements": layout.elements(snapshot.element)]
        case .full: return ["app": app, "display": display, "root": layout.json(application: snapshot.element)]
        }
    }

    /// Reads the light tree until `selector` names one onscreen element, and returns it with its summary. Fails with
    /// `no-element` when none appears within `limit`; reads once when `limit` is zero.
    func element(_ selector: ElementSelector, within limit: Duration) async throws -> (element: PlacedElement, json: JSONValue) {
        let deadline = ContinuousClock.now + limit
        while true {
            let (snapshot, _, layout) = try await read(detail: .light)
            if let found = try selector.resolve(in: layout.placedElements(snapshot.element)) {
                return (found, layout.summary(found))
            }
            guard ContinuousClock.now < deadline else {
                throw SimDriveError(.noElement, "No onscreen element matches \(selector.argument) within \(Self.milliseconds(limit)) "
                                    + "ms; read the tree to see the labels and identifiers on screen.")
            }
            try await Task.sleep(for: Self.elementPollInterval)
        }
    }

    /// The one onscreen element `selector` names now, or nil while none is on screen, though some may be scrolled away.
    func shownElement(_ selector: ElementSelector) async throws -> (element: PlacedElement, json: JSONValue)? {
        let (snapshot, _, layout) = try await read(detail: .light)
        let elements = layout.placedElements(snapshot.element)
        guard selector.isShown(in: elements), let found = try selector.resolve(in: elements) else { return nil }
        return (found, layout.summary(found))
    }

    /// Reads the light tree until `selector` names no onscreen element, failing with `element-still-shown` after `limit`.
    func waitUntilGone(_ selector: ElementSelector, within limit: Duration) async throws {
        let deadline = ContinuousClock.now + limit
        while true {
            let (snapshot, _, layout) = try await read(detail: .light)
            guard selector.isShown(in: layout.placedElements(snapshot.element)) else { return }
            guard ContinuousClock.now < deadline else {
                throw SimDriveError(.elementStillShown, "\(selector.argument) is still on screen after "
                                    + "\(Self.milliseconds(limit)) ms.")
            }
            try await Task.sleep(for: Self.elementPollInterval)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }

    /// The frontmost app's hierarchy and the layout that places it on the screen.
    private func read(detail: TreeDetail) async throws -> (AccessibilitySnapshot, Screen, AccessibilityLayout) {
        let accessibility = try await connected()
        let screen = try await screens.screen(.automatic, usesPixels: false)
        let snapshot = try await accessibility.snapshot(detail: detail)
        let fullLayout = AccessibilityLayout(appSize: snapshot.application.screenSize, scale: device.screenScale, screen: screen)
        let fillsHalf = fullLayout.spansUnder(Self.halfWidthLimit, windows: snapshot.element.children.map(\.frame))
        let layout = AccessibilityLayout(appSize: snapshot.application.screenSize, scale: device.screenScale, screen: screen,
                                         appOrigin: appOrigin(fillsHalf: fillsHalf, pid: snapshot.application.pid))
        return (snapshot, screen, layout)
    }

    /// The element VoiceOver finds at a point, with its descendants when full.
    func element(at point: ScreenPoint, detail: TreeDetail) async throws -> JSONValue {
        let accessibility = try await connected()
        let screen = try await screens.screen(.automatic, usesPixels: point.usesPixels)
        let fraction = screen.normalizedPoint(point)
        let scale = device.screenScale
        let panelPoint: @Sendable (CGSize) -> CGPoint = {
            AccessibilityLayout(appSize: $0, scale: scale, screen: screen).panelPoint(fraction)
        }
        let noElement = SimDriveError(.noElement, "No accessibility element is at \(fraction.x), \(fraction.y).")
        guard let snapshot = try await accessibility.snapshot(at: panelPoint, display: screen.display?.index ?? 0, detail: detail) else {
            throw noElement
        }
        let pid = snapshot.application.pid
        let origin = split.layout(forApp: pid)?.isHalf == true ? appOrigin(fillsHalf: try await frontmostFill().fillsHalf, pid: pid) : 0
        let layout = AccessibilityLayout(appSize: snapshot.application.screenSize, scale: scale, screen: screen, appOrigin: origin)
        // Web content can answer with an element away from the point.
        guard layout.contains(fraction, in: snapshot.element) else { throw noElement }
        let element = switch detail {
        case .light: layout.summary(snapshot.element)
        case .full: layout.json(snapshot.element)
        }
        return ["app": snapshot.application.json, "display": JSONValue(screen.display?.index), "point": screen.json(point),
                "element": element]
    }

    /// The frontmost app, and whether its windows fill one half of a split screen.
    func frontmostFill() async throws -> (fillsHalf: Bool, pid: Int32?) {
        let screen = try await screens.screen(.automatic, usesPixels: false)
        let (application, frames) = try await connected().windows()
        let fillsHalf = AccessibilityLayout(appSize: application.screenSize, scale: device.screenScale, screen: screen)
            .spansUnder(Self.halfWidthLimit, windows: frames)
        return (fillsHalf, application.pid)
    }

    /// Only the half simdrive set for this app says which half it fills; without one, frames start at the left edge.
    private func appOrigin(fillsHalf: Bool, pid: Int32?) -> CGFloat {
        guard fillsHalf, let layout = split.layout(forApp: pid), layout.isHalf else { return 0 }
        return layout.appOrigin
    }

    /// Whether the app of `pid` comes to the front within `limit`; true when accessibility cannot tell.
    func becomesFrontmost(_ pid: Int, within limit: Duration) async -> Bool {
        guard let accessibility = try? await accessibility.value() else { return true }
        let deadline = ContinuousClock.now + limit
        repeat {
            // A launching app answers with nothing at first.
            if let application = try? await accessibility.application() {
                guard let frontmost = application.pid else { return true }
                if Int(frontmost) == pid { return true }
            }
            try? await Task.sleep(for: Self.frontmostPollInterval)
        } while ContinuousClock.now < deadline
        return false
    }

    /// The frontmost app, or "unsupported".
    func doctorJSON() async throws -> JSONValue {
        guard let accessibility = try await accessibility.value() else { return .unsupported }
        return try await accessibility.application().json
    }

    private func connected() async throws -> SimulatorAccessibility {
        try await accessibility.required(orThrow: SimDriveError(.accessibilityUnsupported,
                                                                "CoreSimulator cannot read \(device.name)'s accessibility."))
    }
}
