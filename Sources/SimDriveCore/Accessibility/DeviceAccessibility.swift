import CoreGraphics
import SimDriveNative

/// The frontmost app's accessibility hierarchy, placed in the screen fractions that `tap` takes.
@MainActor
final class DeviceAccessibility {
    private static let frontmostPollInterval: Duration = .milliseconds(100)
    /// A light tree read takes tens of milliseconds, so this keeps waits responsive without reading continuously.
    private static let elementPollInterval: Duration = .milliseconds(200)
    /// How often, and how many times at most, the screen is read again until two reads match.
    private static let restInterval: Duration = .milliseconds(150)
    private static let restReads = 8
    /// A split app's window is about 0.49 of the screen wide, and a full one 1.
    private static let halfWidthLimit = 0.75
    /// A cold iPhone boot started its screen about 85 s in, but a command usually arrives after `bootstatus`, later.
    private static let startLimit: Duration = .seconds(60)
    private static let startPoll: Duration = .milliseconds(250)

    private let device: SimulatorDevice
    private let screens: Screens
    private let split: SplitState
    private let accessibility: LazyCapability<SimulatorAccessibility>
    private let isAppAccessibilityEnabled: @MainActor () async throws -> Bool

    init(device: SimulatorDevice, screens: Screens, split: SplitState,
         isAppAccessibilityEnabled: @escaping @MainActor () async throws -> Bool) {
        self.device = device
        self.screens = screens
        self.split = split
        self.isAppAccessibilityEnabled = isAppAccessibilityEnabled
        accessibility = LazyCapability {
            try await Self.waitForStartedScreen(of: device)
            return try await SimulatorAccessibility.open(device: device)
        }
    }

    /// Holds back the first accessibility read until the guest has started a screen. A read sent earlier in a boot is
    /// what left the Duo's server unanswering until a reboot (F15), as AXe also found. Apple TV reports no started screen,
    /// and its reads were never affected, so it does not wait.
    private static func waitForStartedScreen(of device: SimulatorDevice) async throws {
        guard device.hasTouchscreen else { return }
        let started = try await poll(every: startPoll, within: startLimit) { try await device.hasStartedScreen() ? true : nil }
        guard started == true else {
            throw SimDriveError(.simulatorStarting, "\(device.name) has not started its screen within \(startLimit.components.seconds) s, "
                                + "so its accessibility was not read: a read this early can stop it answering until a reboot. Retry "
                                + "once a screenshot shows the Home screen or an app.")
        }
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
    func element(_ selector: ElementSelector, within limit: Duration)
        async throws -> (element: PlacedElement, json: JSONValue, pid: Int32?, screen: [PlacedElement]) {
        let found = try await poll(every: Self.elementPollInterval, within: limit, finishingChecks: true) {
            let (snapshot, _, layout) = try await self.read(detail: .light)
            let elements = layout.placedElements(snapshot.element)
            return try selector.resolve(in: elements).map { (element: $0, json: layout.summary($0), pid: snapshot.application.pid,
                                                             screen: elements) }
        }
        guard let found else {
            throw SimDriveError(.noElement, "No onscreen element matches \(selector.argument) within \(Self.milliseconds(limit)) "
                                + "ms; read the tree to see the labels and identifiers on screen.")
        }
        return found
    }

    /// The one onscreen element `selector` names, or nil while none is on screen, read once the screen is at rest: once
    /// two reads in a row have the same signature, which is returned too, so a scroll can tell whether it moved anything.
    func shownElementAtRest(_ selector: ElementSelector)
        async throws -> (found: (element: PlacedElement, json: JSONValue)?, signature: String) {
        var (layout, elements) = try await placedElements()
        var signature = PlacedElement.signature(of: elements)
        for _ in 0..<Self.restReads {
            try await Task.sleep(for: Self.restInterval)
            let next = try await placedElements()
            let nextSignature = PlacedElement.signature(of: next.elements)
            (layout, elements) = next
            guard nextSignature != signature else { break }
            signature = nextSignature
        }
        guard selector.isShown(in: elements), let found = try selector.resolve(in: elements) else { return (nil, signature) }
        return ((found, layout.summary(found)), signature)
    }

    private func placedElements() async throws -> (layout: AccessibilityLayout, elements: [PlacedElement]) {
        let (snapshot, _, layout) = try await read(detail: .light)
        return (layout, layout.placedElements(snapshot.element))
    }

    /// Reads the light tree until `selector` names no onscreen element, failing with `element-still-shown` after `limit`.
    func waitUntilGone(_ selector: ElementSelector, within limit: Duration) async throws {
        let gone = try await poll(every: Self.elementPollInterval, within: limit, finishingChecks: true) {
            let (snapshot, _, layout) = try await self.read(detail: .light)
            return selector.isShown(in: layout.placedElements(snapshot.element)) ? nil : true
        }
        guard gone == true else {
            throw SimDriveError(.elementStillShown, "\(selector.argument) is still on screen after \(Self.milliseconds(limit)) ms.")
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int((duration / .milliseconds(1)).rounded())
    }

    /// The frontmost app's hierarchy and the layout that places it on the screen.
    /// An app launched while app accessibility was off answers with an empty frame until it relaunches; that read
    /// fails as `app-accessibility-off` rather than the translator's own error.
    private func explainingAccessibilityOff<Value>(_ read: () async throws -> Value) async throws -> Value {
        do {
            return try await read()
        } catch let error as SimDriveError where error.code == .accessibilityTranslation {
            guard !(try await isAppAccessibilityEnabled()) else { throw error }
            throw SimDriveError(.appAccessibilityOff, "The frontmost app launched while app accessibility was off, as it is once "
                                + "Full Keyboard Access or another accessibility service quits; relaunch it with `launch`.")
        }
    }

    private func read(detail: TreeDetail) async throws -> (AccessibilitySnapshot, Screen, AccessibilityLayout) {
        let accessibility = try await connected()
        let screen = try await screens.screen(.automatic, usesPixels: false)
        let snapshot = try await explainingAccessibilityOff { try await accessibility.snapshot(detail: detail) }
        let fullLayout = AccessibilityLayout(appSize: snapshot.application.screenSize, scale: device.screenScale, screen: screen)
        let fillsHalf = fullLayout.spansUnder(Self.halfWidthLimit, windows: snapshot.element.children.map(\.frame))
        let layout = AccessibilityLayout(appSize: snapshot.application.screenSize, scale: device.screenScale, screen: screen,
                                         appOrigin: appOrigin(fillsHalf: fillsHalf, pid: snapshot.application.pid))
        return (snapshot, screen, layout)
    }

    /// Fails with `element-covered` when something else is at the element's tap point, such as the keyboard, an alert or
    /// a sheet, so a tap there would reach that instead. Nothing at the point counts as clear.
    func checkReachable(_ target: PlacedElement, in targetPID: Int32?, among screenElements: [PlacedElement],
                        as selector: ElementSelector) async throws {
        let accessibility = try await connected()
        let screen = try await screens.screen(.automatic, usesPixels: false)
        let scale = device.screenScale
        let fraction = target.fraction
        let panelPoint: @Sendable (CGSize) -> CGPoint = {
            AccessibilityLayout(appSize: $0, scale: scale, screen: screen).panelPoint(fraction)
        }
        guard let hit = try await accessibility.snapshot(at: panelPoint, display: screen.display?.index ?? 0, detail: .light),
              !ElementSelector.hitReaches(target.element, in: targetPID, hit: hit.element, in: hit.application.pid,
                                          among: screenElements) else { return }
        let cover = hit.element.label ?? hit.element.identifier ?? hit.element.type.map { "a \($0)" } ?? "another element"
        let owner = hit.application.pid == targetPID ? "" : " of \(hit.application.name ?? "another app")"
        throw SimDriveError(.elementCovered, "\(selector.argument) is covered by \(cover)\(owner) at its tap point; dismiss it "
                            + "first, as with key escape or by tapping outside it.")
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
        guard let snapshot = try await explainingAccessibilityOff({
            try await accessibility.snapshot(at: panelPoint, display: screen.display?.index ?? 0, detail: detail)
        }) else {
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
    /// The limit bounds each read too, whose own retries once stretched a 30 s wait to about 50 s (I18).
    func becomesFrontmost(_ pid: Int, within limit: Duration) async -> Bool {
        guard let accessibility = try? await accessibility.value() else { return true }
        let front = try? await poll(every: Self.frontmostPollInterval, within: limit) { () -> Bool? in
            // A launching app answers with nothing at first.
            guard let application = try? await accessibility.application() else { return nil }
            guard let frontmost = application.pid else { return true }
            return Int(frontmost) == pid ? true : nil
        }
        return front == true
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
