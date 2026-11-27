import AppKit
import Foundation
import SimDriveNative

/// One device's services, opened on first use: a booted simulator's, or a connected physical device's. Each command runs
/// here and returns its JSON result. Input, orientation, the pasteboard, screenshots, settings and apps work on both;
/// the rest needs CoreSimulator, so a physical device fails it with the capability's `-unsupported` code.
@MainActor
final class DeviceSession {
    /// UIKit in the guest turns it into a shake motion event, as Simulator's Device > Shake posts it.
    private static let shakeNotification = "com.apple.UIKit.SimulatorShake"

    /// What only a simulator has: CoreSimulator's device, and what needs it.
    private struct SimulatorParts {
        let device: SimulatorDevice
        let bootedAt: Date?
        let accessibility: DeviceAccessibility
        let splitView: SplitView
        let apps: DeviceApps
    }

    private let target: DeviceTarget
    private let name: String
    private let hasTouchscreen: Bool
    private let simulator: SimulatorParts?
    private let tools: DeveloperTools
    private let inputs: DeviceInputs
    private let screens: Screens
    private let wake: DisplayWake
    private let power: any PowerSource
    private let split: SplitState
    private let settings: DeviceSettings
    private let apps: any AppControl
    /// A simulator's logs, or a physical device's app output and crash reports.
    private let logs: DeviceLogs
    private let orientation: LazyCapability<GuestOrientation>
    private let pasteboard: LazyCapability<CoreDevicePasteboard>
    private let hinge: LazyCapability<Hinge>
    /// How a physical device lay before simdrive first set its orientation, put back when the session closes: a set
    /// orientation holds there until set again.
    private var orientationToRestore: PhysicalOrientation?

    private convenience init(simulator device: SimulatorDevice, tools: DeveloperTools, guest: Guest) {
        let udid = device.udid
        let coreDevice = LazyCapability(isUsable: { !$0.hasFailed }) { try await CoreDeviceRemote.open(device: device) }
        let hinge = LazyCapability<Hinge>(isUsable: { !$0.hasFailed }, close: { $0.stop() }) {
            try await Hinge.open(device: device, remote: { try await coreDevice.value() })
        }
        let source = SimulatorScreens(udid: udid, device: device, tools: tools)
        let settingActions = LazyCapability { GuestSettingActions.open(guest: guest) }
        let settings = DeviceSettings(id: udid, name: device.name, majorOSVersion: device.majorOSVersion, simulator: device, tools: tools,
                                      actions: { try await settingActions.required(orThrow: Self.noSettingActions(device.name)) })
        self.init(target: DeviceTarget(kind: .simulator, id: udid), name: device.name, hasTouchscreen: device.hasTouchscreen,
                  tools: tools, guest: guest, source: source, bootedAt: device.lastBootedAt, simulator: device, power: device,
                  settings: settings, coreDevice: { try await coreDevice.value() }, hinge: hinge)
    }

    private convenience init(physical record: PhysicalDeviceRecord, remote: CoreDeviceRemote, tools: DeveloperTools, guest: Guest) {
        let capture = LazyCapability { try await GuestScreenCapture.open(guest: guest) }
        let source = DeviceScreens(name: record.name, hasTouchscreen: !record.isAppleTV, capture: capture)
        let settingActions = LazyCapability { GuestSettingActions.open(guest: guest) }
        let settings = DeviceSettings(id: record.identifier.uuidString, name: record.name, majorOSVersion: record.majorOSVersion,
                                      simulator: nil, tools: tools,
                                      actions: { try await settingActions.required(orThrow: Self.noSettingActions(record.name)) })
        let power = DevicePower(name: record.name, displays: LazyCapability { try await CoreDeviceDisplays.open(remote: remote) })
        self.init(target: DeviceTarget(kind: .physical, id: record.identifier.uuidString), name: record.name,
                  hasTouchscreen: !record.isAppleTV, tools: tools, guest: guest, source: source, bootedAt: nil, simulator: nil,
                  power: power, settings: settings, coreDevice: { remote }, hinge: LazyCapability { nil })
    }

    private init(target: DeviceTarget, name: String, hasTouchscreen: Bool, tools: DeveloperTools, guest: Guest, source: any ScreenSource,
                 bootedAt: Date?, simulator device: SimulatorDevice?, power: any PowerSource, settings: DeviceSettings,
                 coreDevice: @escaping @MainActor () async throws -> CoreDeviceRemote?, hinge: LazyCapability<Hinge>) {
        self.target = target
        self.name = name
        self.hasTouchscreen = hasTouchscreen
        self.tools = tools
        self.settings = settings
        self.hinge = hinge
        self.power = power
        let orientation = LazyCapability(isUsable: { !$0.hasFailed }) { try await GuestOrientation.open(guest: guest) }
        self.orientation = orientation
        pasteboard = LazyCapability(isUsable: { !$0.hasFailed }) { try await CoreDevicePasteboard.open(guest: guest, remote: coreDevice) }
        let inputs = DeviceInputs(guest: guest)
        self.inputs = inputs
        let screens = Screens(id: target.id, source: source, bootedAt: bootedAt, orientation: orientation, hinge: hinge)
        self.screens = screens
        wake = DisplayWake(power: power, inputs: inputs)
        let split = SplitState()
        self.split = split
        guard let device else {
            simulator = nil
            let logs = DeviceLogs(device: DeviceAppProcesses(id: target.id, tools: tools))
            self.logs = logs
            apps = DeviceAppControl(id: target.id, tools: tools, screens: screens, logs: logs)
            return
        }
        let accessibility = DeviceAccessibility(device: device, screens: screens, split: split,
                                                isAppAccessibilityEnabled: { try await settings.isApplicationAccessibilityEnabled() })
        let logs = DeviceLogs(udid: target.id, tools: tools)
        self.logs = logs
        let deviceApps = DeviceApps(udid: target.id, tools: tools)
        simulator = SimulatorParts(device: device, bootedAt: bootedAt, accessibility: accessibility,
                                   splitView: SplitView(screens: screens, state: split, inputs: inputs, accessibility: accessibility, logs: logs),
                                   apps: deviceApps)
        apps = SimulatorApps(device: device, apps: deviceApps, launcher: AppLauncher(udid: target.id, device: device, tools: tools, settings: settings,
                                                                    logs: logs, screens: screens, accessibility: accessibility))
    }

    static func open(_ target: DeviceTarget, tools: DeveloperTools) async throws -> DeviceSession {
        switch target.kind {
        case .simulator:
            let device = try SimulatorDevice.find(udid: target.id, developerDirectory: tools.developerDirectory)
            guard device.isBooted else {
                throw SimDriveError(.notBooted, "\(device.name) is \(device.state ?? "not booted"); boot it first.")
            }
            let guest = try await Guest(simulator: device)
            try StatePaths.prepare()
            return DeviceSession(simulator: device, tools: tools, guest: guest)
        case .physical:
            guard let record = try await PhysicalDevices.paired().first(where: { $0.isNamed(target.id) }) else {
                throw SimDriveError(.deviceNotConnected, "CoreDevice no longer lists the device \(target.id).")
            }
            let remote = try await CoreDeviceRemote.open(physical: record)
            let guest = try await Guest(physical: remote)
            try StatePaths.prepare()
            return DeviceSession(physical: record, remote: remote, tools: tools, guest: guest)
        }
    }

    /// Starts the guest's accessibility server in the background, for a session that outlives its first command. A
    /// one-shot run must not: it exits while the read runs on the translator's queue, which crashed in `AXPTranslator`.
    func warmUpAccessibility() {
        simulator?.accessibility.prepare()
    }

    private static func noSettingActions(_ name: String) -> SimDriveError {
        SimDriveError(.settingUnsupported, "\(name) has no setting actions.")
    }

    /// The simulator's parts, or `code` on a physical device, which lacks `what`.
    private func simulatorOnly(_ code: ErrorCode, _ what: String) throws -> SimulatorParts {
        guard let simulator else {
            throw SimDriveError(code, "\(name) is a physical device, which simdrive cannot \(what) yet.")
        }
        return simulator
    }

    private func accessibility() throws -> DeviceAccessibility {
        try simulatorOnly(.accessibilityUnsupported, "read the accessibility of").accessibility
    }

    func execute(_ command: Command, workingDirectory: String) async throws -> JSONValue {
        switch command {
        case .key(let name, let modifiers, let count):
            return try await pressKey(name, modifiers: modifiers, count: count)
        case .type(let text):
            return try await type(text)
        case .tap(let point, let display):
            return try await tap(point, display: display)
        case .tapElement(let selector, let timeout):
            return try await tap(selector, within: timeout)
        case .swipe(let path, let duration, let edge, let display):
            return try await swipe(through: path, duration: duration, edge: edge, display: display)
        case .swipeUntil(let path, let duration, let selector, let maxSwipes):
            return try await swipe(through: path, duration: duration, until: selector, maxSwipes: maxSwipes)
        case .pinch(let center, let scale, let duration, let display):
            return try await twoFingerGesture(around: center, duration: duration, display: display, result: ["scale": .number(scale)]) {
                TwoFingerGesture.pinch(around: $0, scale: scale, screen: $1)
            }
        case .rotate(let center, let degrees, let duration, let display):
            return try await twoFingerGesture(around: center, duration: duration, display: display, result: ["degrees": .number(degrees)]) {
                TwoFingerGesture.rotation(around: $0, degrees: degrees, screen: $1)
            }
        case .button(let button, let count, let hold, let legacy):
            return try await press(button, count: count, hold: hold, legacy: legacy)
        case .posture(let posture?):
            return try await setPosture(posture)
        case .posture(nil):
            return try await readPosture()
        case .split(let layout, let current):
            return try await simulatorOnly(.splitUnsupported, "split the screen of").splitView.move(to: layout, from: current)
        case .orientation(let orientation?):
            let control = try await connectedOrientation()
            let woke = hasTouchscreen ? try await wake.wake(screens.touchscreen(.automatic, usesPixels: false)) : false
            if target.kind == .physical, orientationToRestore == nil { orientationToRestore = try await control.read().physical }
            return Self.noting(woke: woke, in: try await control.set(orientation).json)
        case .orientation(nil):
            return try await connectedOrientation().read().json
        case .pasteboard(let text?):
            return try await writePasteboard(text)
        case .pasteboard(nil):
            return try await readPasteboard()
        case .screenshot(let path, let display, let maxDimension):
            return try await screens.screenshot(to: Self.absolutePath(path, in: workingDirectory), display: display,
                                                maxDimension: maxDimension)
        case .tree(let point?, let detail, _, _):
            return try await accessibility().element(at: point, detail: detail)
        case .tree(nil, let detail, let covered, let bundleID):
            let accessibility = try accessibility()
            var pid: Int32?
            if let bundleID, let simulator { pid = try await simulator.apps.runningProcess(of: bundleID) }
            return try await accessibility.tree(detail: detail, marksCovered: covered, process: pid)
        case .setting(let setting?, let value?):
            return try await settings.set(setting, to: value)
        case .setting(let setting?, nil):
            return try await settings.read(setting)
        case .setting(nil, _):
            return try await settings.all()
        case .launch(let bundleID, let arguments):
            return try await apps.launch(bundleID, arguments: arguments)
        case .install(let path):
            return try await apps.install(Self.absolutePath(path, in: workingDirectory))
        case .uninstall(let bundleID):
            return try await apps.uninstall(bundleID)
        case .openURL(let url):
            return try await apps.open(url)
        case .push(let bundleID, let payload):
            return try await simulatorOnly(.pushUnsupported, "push notifications to").apps
                .push(payload, to: bundleID, workingDirectory: workingDirectory)
        case .privacy(let action, let service, let bundleID):
            return try await simulatorOnly(.privacyUnsupported, "change app privacy on").apps
                .privacy(action, service: service, bundleID: bundleID)
        // A physical device refuses `devicectl device simulate statusBar`: "Simulate Status Bar is not supported".
        case .statusBar(let override?):
            _ = try simulatorOnly(.statusBarUnsupported, "override the status bar of")
            try await tools.simctl(["status_bar", target.id, "override"] + override.simctlArguments)
            return ["overrides": .object(override.values.mapValues(JSONValue.string))]
        case .statusBar(nil):
            _ = try simulatorOnly(.statusBarUnsupported, "override the status bar of")
            try await tools.simctl(["status_bar", target.id, "clear"])
            return ["cleared": true]
        case .wait(let milliseconds):
            try await Task.sleep(for: .milliseconds(milliseconds))
            return ["waited": JSONValue(milliseconds)]
        case .waitForElement(let selector, gone: false, let timeout):
            let found = try await accessibility().element(selector, within: timeout)
            return ["element": found.json]
        case .waitForElement(let selector, gone: true, let timeout):
            try await accessibility().waitUntilGone(selector, within: timeout)
            return ["absent": true]
        case .logs(let query):
            return try await logs.read(query)
        case .run(let steps, let attachesLogs):
            return try await run(steps, attachesLogs: attachesLogs, workingDirectory: workingDirectory)
        case .alert(let answer, let timeout):
            return try await alert(answer, within: timeout)
        case .shake:
            try simulatorOnly(.shakeUnsupported, "shake").device.postDarwinNotification(Self.shakeNotification)
            return [:]
        case .memoryWarning:
            try await apps.memoryWarning()
            return [:]
        case .doctor:
            return await doctor()
        case .stop, .serve:
            throw SimDriveError(.notADeviceCommand, "This command is handled by the command line, not a device session.")
        }
    }

    /// Whether a simulator still runs the boot the session opened in; its guest connections end with that boot. A
    /// physical device's connections that end are opened again by the parts that use them.
    var isCurrent: Bool {
        guard let simulator else { return true }
        return simulator.device.isBooted && simulator.device.lastBootedAt == simulator.bootedAt
    }

    /// Releases the inputs, as after an idle period; the next command opens them again.
    func releaseInputs() async {
        await inputs.release()
    }

    func close() async {
        await inputs.release()
        await hinge.close()
        await restoreOrientation()
    }

    /// Puts a physical device back as it lay before simdrive set its orientation, which otherwise holds.
    private func restoreOrientation() async {
        guard let physical = orientationToRestore else { return }
        orientationToRestore = nil
        try? await orientation.value()?.restore(physical)
    }

    // MARK: Keyboard

    private func pressKey(_ name: String, modifiers: Set<KeyModifier>, count: Int) async throws -> JSONValue {
        guard let stroke = KeyMap.stroke(named: name) else { throw SimDriveError(.unknownKey, "Unknown key \(name).") }
        try await inputs.press(stroke, modifiers: NSEvent.ModifierFlags(modifiers.map(\.flag)), count: count)
        return ["key": .string(name), "modifiers": .array(modifiers.map(\.rawValue).sorted().map(JSONValue.string)),
                "count": JSONValue(count)]
    }

    /// Types on the guest's hardware keyboard layout; other text goes through the pasteboard. A physical device's layout
    /// cannot be read from the Mac, so it is taken as US.
    private func type(_ text: String) async throws -> JSONValue {
        let (keys, layout) = try KeyMap.keys(for: text, layout: simulator.flatMap { KeyboardLayout.active(on: $0.device) })
        try await inputs.type(keys)
        return ["characters": JSONValue(text.count), "layout": .string(layout)]
    }

    // MARK: Touches and buttons

    private func tap(_ point: ScreenPoint, display: DisplaySelector) async throws -> JSONValue {
        let screen = try await screens.touchscreen(display, usesPixels: point.usesPixels)
        let woke = try await wake.wake(screen)
        try await inputs.tap(at: screen.digitizerPoint(point), on: screen.digitizerTarget)
        return Self.noting(woke: woke, in: ["display": JSONValue(screen.display?.index), "point": screen.json(point)])
    }

    /// Taps the element's tap point once the pixels there hold still, and reports the element, whose `point` says where,
    /// and the wait.
    private func tap(_ selector: ElementSelector, within limit: Duration) async throws -> JSONValue {
        let accessibility = try accessibility()
        let found = try await accessibility.element(selector, within: limit)
        try await accessibility.checkReachable(found.element, in: found.pid, among: found.screen, as: selector)
        return try await tapOnceStill(found.element, ["element": found.json])
    }

    /// Taps a placed element's point once the pixels there hold still, adding the display and the wait to `result`.
    private func tapOnceStill(_ element: PlacedElement, _ result: [String: JSONValue]) async throws -> JSONValue {
        let screen = try await screens.touchscreen(.automatic, usesPixels: false)
        let point = ScreenPoint.normalized(element.fraction)
        let woke = try await wake.wake(screen)
        let settle = try await screens.settle(around: point, on: screen)
        try await inputs.tap(at: screen.digitizerPoint(point), on: screen.digitizerTarget)
        return Self.noting(woke: woke, in: .object(result.merging([
            "display": JSONValue(screen.display?.index),
            "settle": settle.map { ["waited": JSONValue(Int(($0.waited / .milliseconds(1)).rounded())), "still": .bool($0.still)] } ?? .null,
        ]) { $1 }))
    }

    /// Reads the newest alert, waiting up to `limit` for one; with an answer, taps the button that gives it.
    private func alert(_ answer: AlertAnswer?, within limit: Duration) async throws -> JSONValue {
        let found = try await accessibility().alert(within: limit)
        guard let answer else { return ["app": found?.app ?? .null, "alert": found?.json ?? .null] }
        guard let found else {
            throw SimDriveError(.noAlert, "No alert showed within \(Int((limit / .milliseconds(1)).rounded())) ms; take a screenshot to "
                                + "see what is on screen.")
        }
        guard let button = found.button(for: answer) else {
            throw SimDriveError(.noAlert, "No button of the alert reads as a way to \(answer.rawValue) it, so none was tapped; read "
                                + "its buttons with `alert` and `tap --label` the one you mean.")
        }
        return try await tapOnceStill(button.placed, ["app": found.app, "alert": found.json, "button": button.json])
    }

    private func twoFingerGesture(around center: ScreenPoint, duration: Duration, display: DisplaySelector, result: [String: JSONValue],
                                  _ layout: (CGPoint, CGSize) -> TwoFingerGesture) async throws -> JSONValue {
        let screen = try await screens.touchscreen(display, usesPixels: center.usesPixels)
        let size = CGSize(width: screen.record.image.width, height: screen.record.image.height)
        let gesture = layout(screen.normalizedPoint(center), size)
        let woke = try await wake.wake(screen)
        try await inputs.drag(through: gesture.first.map { screen.digitizerPoint(.normalized($0)) },
                              and: gesture.second.map { screen.digitizerPoint(.normalized($0)) }, duration: duration,
                              on: screen.digitizerTarget)
        return Self.noting(woke: woke, in: .object(result.merging(["display": JSONValue(screen.display?.index),
                                                                   "center": screen.json(center)]) { $1 }))
    }

    private func swipe(through path: [ScreenPoint], duration: Duration, edge: ScreenEdge?,
                       display: DisplaySelector) async throws -> JSONValue {
        let screen = try await screens.touchscreen(display, usesPixels: path.contains { $0.usesPixels })
        let woke = try await wake.wake(screen)
        try await inputs.drag(through: path.map(screen.digitizerPoint), duration: duration,
                              edge: edge.map(screen.mapping.digitizerEdge), on: screen.digitizerTarget)
        var result: [String: JSONValue] = ["display": JSONValue(screen.display?.index), "from": screen.json(path[0]),
                                           "to": screen.json(path[path.count - 1]), "edge": JSONValue(edge?.rawValue)]
        if path.count > 2 {
            result["via"] = .array(path.dropFirst().dropLast().map(screen.json))
        }
        return Self.noting(woke: woke, in: .object(result))
    }

    /// Swipes until the element is on screen, reading the tree first so a shown element costs no swipe. Each swipe holds
    /// still at its end before lifting, so the content moves the swipe's length and does not fling past the element; a
    /// swipe that moves nothing means the content reached its end, so it stops there.
    private func swipe(through path: [ScreenPoint], duration: Duration, until selector: ElementSelector,
                       maxSwipes: Int) async throws -> JSONValue {
        let segments = path.count - 1
        // Each segment of a path takes equal time, so a repeated last point holds for one segment's time.
        let restingPath = path + [path[path.count - 1]]
        let restingDuration = duration * (segments + 1) / segments
        var swipes = 0
        var before: String?
        var woke = false
        while true {
            let seen = try await accessibility().shownElementAtRest(selector)
            if let found = seen.found {
                return Self.noting(woke: woke, in: ["element": found.json, "swipes": JSONValue(swipes)])
            }
            if seen.signature == before {
                throw SimDriveError(.noElement, "No onscreen element matches \(selector.argument): swipe \(swipes) moved nothing, "
                                    + "so the content is at its end; swipe the other way.")
            }
            guard swipes < maxSwipes else {
                throw SimDriveError(.noElement, "No onscreen element matches \(selector.argument) after \(swipes) swipes; "
                                    + "swipe the other way, or raise --max-swipes.")
            }
            before = seen.signature
            let swiped = try await swipe(through: restingPath, duration: restingDuration, edge: nil, display: .automatic)
            if case .object(let fields) = swiped, fields["woke"] == true { woke = true }
            swipes += 1
        }
    }

    private func press(_ button: HardwareButton, count: Int, hold: Duration, legacy: Bool) async throws -> JSONValue {
        try await inputs.press(button, count: count, hold: hold, legacy: legacy)
        if button == .home { screens.forgetScreenshots() }
        return ["button": .string(button.rawValue), "count": JSONValue(count)]
    }

    // MARK: Orientation, pasteboard and posture

    private func connectedOrientation() async throws -> GuestOrientation {
        try await orientation.required(orThrow: SimDriveError(.orientationUnsupported, "\(name) cannot rotate."))
    }

    private func readPasteboard() async throws -> JSONValue {
        ["items": .array(try await connectedPasteboard().read().map(\.json))]
    }

    private func writePasteboard(_ text: String) async throws -> JSONValue {
        try await connectedPasteboard().write(text: text)
        return ["characters": JSONValue(text.count)]
    }

    private func connectedPasteboard() async throws -> CoreDevicePasteboard {
        try await pasteboard.required(orThrow: SimDriveError(.pasteboardUnsupported, "\(name) has no pasteboard."))
    }

    private func readPosture() async throws -> JSONValue {
        let hinge = try await connectedHinge()
        try await hinge.waitForReading()
        return hinge.json
    }

    private func setPosture(_ posture: DevicePosture) async throws -> JSONValue {
        let hinge = try await connectedHinge()
        // Folding moves the app to the cover screen, and unfolding lays it out afresh.
        split.forget()
        try await hinge.set(posture)
        return hinge.json
    }

    private func connectedHinge() async throws -> Hinge {
        try await hinge.required(orThrow: SimDriveError(.postureUnsupported, "\(name) has no hinge."))
    }

    // MARK: Apps, steps and diagnostics

    private func run(_ steps: [Step], attachesLogs: Bool, workingDirectory: String) async throws -> JSONValue {
        var results: [JSONValue] = []
        var starts: [Date] = []
        for (index, step) in steps.enumerated() {
            let previousStart = starts.last
            starts.append(.now)
            do {
                if case .logs(let query) = step.command {
                    results.append(try await logs.read(query, previousStepStart: previousStart))
                } else {
                    results.append(try await execute(step.command, workingDirectory: workingDirectory))
                }
            } catch {
                let retryable = (error as? SimDriveError)?.code.isRetryable ?? false
                throw SimDriveError(.stepFailed(retryable: retryable), "Step \(index + 1) (\(step.arguments.joined(separator: " "))) failed after \(index) "
                                    + "completed: \(error.localizedDescription)")
            }
        }
        guard attachesLogs else { return ["steps": .array(results)] }
        // The steps have run, so a failed read reports itself beside their results.
        do {
            return ["steps": .array(try await logs.attach(to: results, stepStarts: starts))]
        } catch {
            return ["steps": .array(results), "logsError": .string(error.localizedDescription)]
        }
    }

    private func doctor() async -> JSONValue {
        var report: [String: JSONValue] = [
            "developerDirectory": .string(tools.developerDirectory), "device": .string(name), "kind": .string(target.kind.rawValue),
            "state": JSONValue(simulator?.device.state), "deviceType": JSONValue(simulator?.device.deviceTypeIdentifier),
        ]
        report["orientation"] = await Self.check {
            (try await self.screens.deviceOrientation()?.name).map(JSONValue.string) ?? .unsupported
        }
        report["pasteboard"] = await Self.check { try await self.pasteboard.value() == nil ? .unsupported : "ready" }
        report["keyboard"] = await Self.check {
            try await self.inputs.prepareKeyboard()
            return "ready"
        }
        report["displays"] = await Self.check { try await self.screens.displaysJSON() }
        report["backlight"] = await Self.check {
            guard let device = self.simulator?.device else {
                // A physical device has one screen, numbered as a simulator's main screen.
                return try await self.power.backlight(screenID: Screens.mainScreenID).map { [String(Screens.mainScreenID): .string($0.rawValue)] }
                    ?? .unsupported
            }
            let backlights = try await device.backlights()
            guard !backlights.isEmpty else { return .unsupported }
            return .object(Dictionary(uniqueKeysWithValues: backlights.map { (String($0.key), JSONValue.string($0.value.rawValue)) }))
        }
        report["locked"] = await Self.check { try await self.power.isLocked().map(JSONValue.bool) ?? .unsupported }
        report["accessibility"] = await Self.check { try await self.accessibility().doctorJSON() }
        report["appearance"] = await Self.check { try await self.settings.value(of: SettingCatalog.appearance) }
        report["posture"] = await Self.check {
            guard try await self.hinge.value() != nil else { return .unsupported }
            return try await self.readPosture()
        }
        return .object(report)
    }

    /// A result with `"woke": true` when the display had to be woken before the input; unchanged otherwise.
    static func noting(woke: Bool, in result: JSONValue) -> JSONValue {
        guard woke, case .object(var fields) = result else { return result }
        fields["woke"] = true
        return .object(fields)
    }

    private static func check(_ probe: () async throws -> JSONValue) async -> JSONValue {
        do { return try await probe() } catch { return ["error": .string(error.localizedDescription)] }
    }

    private static func absolutePath(_ path: String, in workingDirectory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)).standardizedFileURL.path
    }
}
