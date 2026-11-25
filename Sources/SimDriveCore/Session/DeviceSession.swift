import AppKit
import Foundation
import SimDriveNative

/// One booted simulator's services, opened on first use. Each command runs here and returns its JSON result.
@MainActor
final class DeviceSession {
    /// How long an app may take to come to the front after `simctl launch`, which returns seconds before it does. A
    /// freshly booted, busy simulator takes tens of seconds.
    private static let launchLimit: Duration = .seconds(30)
    /// SpringBoard's lock state, 1 while the device is locked.
    private static let lockStateNotification = "com.apple.springboard.lockstate"
    private let udid: String
    private let device: SimulatorDevice
    private let bootedAt: Date?
    private let tools: DeveloperTools
    private let inputs: DeviceInputs
    private let screens: Screens
    private let accessibility: DeviceAccessibility
    private let splitView: SplitView
    private let split: SplitState
    private let settings: DeviceSettings
    private let logs: DeviceLogs
    private let apps: DeviceApps
    private let orientation: LazyCapability<GuestOrientation>
    private let pasteboard: LazyCapability<CoreDevicePasteboard>
    private let hinge: LazyCapability<Hinge>

    private init(udid: String, device: SimulatorDevice, tools: DeveloperTools, guest: SimulatorGuest) {
        self.udid = udid
        self.device = device
        bootedAt = device.lastBootedAt
        self.tools = tools
        let coreDevice = LazyCapability(isUsable: { !$0.hasFailed }) { try await CoreDeviceRemote.open(device: device) }
        let orientation = LazyCapability(isUsable: { !$0.hasFailed }) { try await GuestOrientation.open(guest: guest) }
        let hinge = LazyCapability<Hinge>(isUsable: { !$0.hasFailed }, close: { $0.stop() }) {
            try await Hinge.open(device: device, remote: { try await coreDevice.value() })
        }
        pasteboard = LazyCapability(isUsable: { !$0.hasFailed }) {
            try await CoreDevicePasteboard.open(guest: guest, remote: { try await coreDevice.value() })
        }
        self.orientation = orientation
        self.hinge = hinge
        inputs = DeviceInputs(guest: guest)
        screens = Screens(udid: udid, device: device, tools: tools, orientation: orientation, hinge: hinge)
        let split = SplitState()
        self.split = split
        accessibility = DeviceAccessibility(device: device, screens: screens, split: split)
        logs = DeviceLogs(udid: udid, tools: tools)
        splitView = SplitView(screens: screens, state: split, inputs: inputs, accessibility: accessibility, logs: logs)
        let settingActions = LazyCapability { GuestSettingActions.open(guest: guest, udid: udid) }
        settings = DeviceSettings(udid: udid, device: device, tools: tools, actions: {
            try await settingActions.required(orThrow: SimDriveError(.settingUnsupported, "\(device.name) has no setting actions."))
        })
        apps = DeviceApps(udid: udid, tools: tools)
    }

    static func open(udid: String, tools: DeveloperTools) async throws -> DeviceSession {
        let device = try SimulatorDevice.find(udid: udid, developerDirectory: tools.developerDirectory)
        guard device.isBooted else {
            throw SimDriveError(.notBooted, "\(device.name) is \(device.state ?? "not booted"); boot it first.")
        }
        let guest = try await SimulatorGuest(device: device)
        try StatePaths.prepare()
        return DeviceSession(udid: udid, device: device, tools: tools, guest: guest)
    }

    /// Starts the guest's accessibility server in the background, for a session that outlives its first command. A
    /// one-shot run must not: it exits while the read runs on the translator's queue, which crashed in `AXPTranslator`.
    func warmUpAccessibility() {
        accessibility.prepare()
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
            return try await splitView.move(to: layout, from: current)
        case .orientation(let orientation?):
            return try await connectedOrientation().set(orientation).json
        case .orientation(nil):
            return try await connectedOrientation().read().json
        case .pasteboard(let text?):
            return try await writePasteboard(text)
        case .pasteboard(nil):
            return try await readPasteboard()
        case .screenshot(let path, let display, let maxDimension):
            return try await screens.screenshot(to: Self.absolutePath(path, in: workingDirectory), display: display,
                                                maxDimension: maxDimension)
        case .tree(let point?, let detail):
            return try await readAccessibility { try await self.accessibility.element(at: point, detail: detail) }
        case .tree(nil, let detail):
            return try await readAccessibility { try await self.accessibility.tree(detail: detail) }
        case .setting(let setting?, let value?):
            return try await settings.set(setting, to: value)
        case .setting(let setting?, nil):
            return try await settings.read(setting)
        case .setting(nil, _):
            return try await settings.all()
        case .launch(let bundleID, let arguments):
            return try await launch(bundleID, arguments: arguments)
        case .install(let path):
            return try await apps.install(Self.absolutePath(path, in: workingDirectory))
        case .uninstall(let bundleID):
            return try await apps.uninstall(bundleID)
        case .openURL(let url):
            return try await openURL(url)
        case .wait(let milliseconds):
            try await Task.sleep(for: .milliseconds(milliseconds))
            return ["waited": JSONValue(milliseconds)]
        case .waitForElement(let selector, gone: false, let timeout):
            let found = try await readAccessibility { try await self.accessibility.element(selector, within: timeout) }
            return ["element": found.json]
        case .waitForElement(let selector, gone: true, let timeout):
            try await readAccessibility { try await self.accessibility.waitUntilGone(selector, within: timeout) }
            return ["absent": true]
        case .logs(let query):
            return try await logs.read(query)
        case .run(let steps, let attachesLogs):
            return try await run(steps, attachesLogs: attachesLogs, workingDirectory: workingDirectory)
        case .doctor:
            return await doctor()
        case .stop, .serve:
            throw SimDriveError(.notADeviceCommand, "This command is handled by the command line, not a device session.")
        }
    }

    /// Whether the device still runs the boot the session opened in; its guest connections end with that boot.
    var isCurrent: Bool { device.isBooted && device.lastBootedAt == bootedAt }

    /// Releases the inputs, as after an idle period; the next command opens them again.
    func releaseInputs() async {
        await inputs.release()
    }

    func close() async {
        await inputs.release()
        await hinge.close()
    }

    // MARK: Keyboard

    private func pressKey(_ name: String, modifiers: Set<KeyModifier>, count: Int) async throws -> JSONValue {
        guard let stroke = KeyMap.stroke(named: name) else { throw SimDriveError(.unknownKey, "Unknown key \(name).") }
        try await inputs.press(stroke, modifiers: NSEvent.ModifierFlags(modifiers.map(\.flag)), count: count)
        return ["key": .string(name), "modifiers": .array(modifiers.map(\.rawValue).sorted().map(JSONValue.string)),
                "count": JSONValue(count)]
    }

    /// Types on the guest's hardware keyboard layout; other text goes through the pasteboard.
    private func type(_ text: String) async throws -> JSONValue {
        let (keys, layout) = try KeyMap.keys(for: text, layout: KeyboardLayout.active(on: device))
        try await inputs.type(keys)
        return ["characters": JSONValue(text.count), "layout": .string(layout)]
    }

    // MARK: Touches and buttons

    private func tap(_ point: ScreenPoint, display: DisplaySelector) async throws -> JSONValue {
        let screen = try await screens.touchscreen(display, usesPixels: point.usesPixels)
        try await inputs.tap(at: screen.digitizerPoint(point), on: screen.digitizerTarget)
        return ["display": JSONValue(screen.display?.index), "point": screen.json(point)]
    }

    /// Taps the element's tap point once the pixels there hold still, and reports the element, whose `point` says where,
    /// and the wait.
    private func tap(_ selector: ElementSelector, within limit: Duration) async throws -> JSONValue {
        let found = try await readAccessibility { try await self.accessibility.element(selector, within: limit) }
        try await accessibility.checkReachable(found.element, in: found.pid, among: found.screen, as: selector)
        let screen = try await screens.touchscreen(.automatic, usesPixels: false)
        let point = ScreenPoint.normalized(found.element.fraction)
        let settle = try await screens.settle(around: point, on: screen)
        try await inputs.tap(at: screen.digitizerPoint(point), on: screen.digitizerTarget)
        return ["display": JSONValue(screen.display?.index), "element": found.json,
                "settle": settle.map { ["waited": JSONValue(Int(($0.waited / .milliseconds(1)).rounded())), "still": .bool($0.still)] }
                    ?? .null]
    }

    private func twoFingerGesture(around center: ScreenPoint, duration: Duration, display: DisplaySelector, result: [String: JSONValue],
                                  _ layout: (CGPoint, CGSize) -> TwoFingerGesture) async throws -> JSONValue {
        let screen = try await screens.touchscreen(display, usesPixels: center.usesPixels)
        let size = CGSize(width: screen.record.image.width, height: screen.record.image.height)
        let gesture = layout(screen.normalizedPoint(center), size)
        try await inputs.drag(through: gesture.first.map { screen.digitizerPoint(.normalized($0)) },
                              and: gesture.second.map { screen.digitizerPoint(.normalized($0)) }, duration: duration,
                              on: screen.digitizerTarget)
        return .object(result.merging(["display": JSONValue(screen.display?.index), "center": screen.json(center)]) { $1 })
    }

    private func swipe(through path: [ScreenPoint], duration: Duration, edge: ScreenEdge?,
                       display: DisplaySelector) async throws -> JSONValue {
        let screen = try await screens.touchscreen(display, usesPixels: path.contains { $0.usesPixels })
        try await inputs.drag(through: path.map(screen.digitizerPoint), duration: duration,
                              edge: edge.map(screen.mapping.digitizerEdge), on: screen.digitizerTarget)
        var result: [String: JSONValue] = ["display": JSONValue(screen.display?.index), "from": screen.json(path[0]),
                                           "to": screen.json(path[path.count - 1]), "edge": JSONValue(edge?.rawValue)]
        if path.count > 2 {
            result["via"] = .array(path.dropFirst().dropLast().map(screen.json))
        }
        return .object(result)
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
        while true {
            let seen = try await readAccessibility { try await self.accessibility.shownElementAtRest(selector) }
            if let found = seen.found {
                return ["element": found.json, "swipes": JSONValue(swipes)]
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
            _ = try await swipe(through: restingPath, duration: restingDuration, edge: nil, display: .automatic)
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
        try await orientation.required(orThrow: SimDriveError(.orientationUnsupported, "\(device.name) cannot rotate."))
    }

    private func readPasteboard() async throws -> JSONValue {
        ["items": .array(try await connectedPasteboard().read().map(\.json))]
    }

    private func writePasteboard(_ text: String) async throws -> JSONValue {
        try await connectedPasteboard().write(text: text)
        return ["characters": JSONValue(text.count)]
    }

    private func connectedPasteboard() async throws -> CoreDevicePasteboard {
        try await pasteboard.required(orThrow: SimDriveError(.pasteboardUnsupported, "\(device.name) has no pasteboard."))
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
        try await hinge.required(orThrow: SimDriveError(.postureUnsupported, "\(device.name) has no hinge."))
    }

    // MARK: Apps, steps and diagnostics

    private func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue {
        try await settings.enableApplicationAccessibility()
        let output = logs.prepareLaunch(dataDirectory: device.dataDirectory)
        let launchedAt = Date.now
        // Restarts a running app, so it starts from its launch screen with these arguments.
        let result = try await tools.simctl(["launch", "--terminate-running-process"] + output.launchOptions + [udid, bundleID] + arguments,
                                            childEnvironment: AppOutput.environment)
        screens.forgetScreenshots()
        // simctl prints `<bundle-id>: <pid>`.
        let pid = result.standardOutput.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        logs.recordLaunch(bundleID: bundleID, pid: pid, at: launchedAt, output: output)
        if let pid, !(await accessibility.becomesFrontmost(pid, within: Self.launchLimit)) {
            throw SimDriveError(.launchNotFrontmost, "\(bundleID) launched as pid \(pid) but did not come to the front within "
                                + "\(Self.launchLimit.components.seconds) s; take a screenshot to see what is in front.")
        }
        return ["bundleID": .string(bundleID), "pid": JSONValue(pid)]
    }

    /// An app launched while app accessibility was off has an empty frame until it relaunches.
    private func readAccessibility<Value>(_ read: () async throws -> Value) async throws -> Value {
        do {
            return try await read()
        } catch let error as SimDriveError where error.code == .accessibilityTranslation {
            guard !(try await settings.isApplicationAccessibilityEnabled()) else { throw error }
            throw SimDriveError(.appAccessibilityOff, "The frontmost app launched while app accessibility was off, as it is once "
                                + "Full Keyboard Access or another accessibility service quits; relaunch it with `launch`.")
        }
    }

    private func openURL(_ url: String) async throws -> JSONValue {
        try await tools.simctl(["openurl", udid, url])
        screens.forgetScreenshots()
        return ["url": .string(url)]
    }

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
        do { return ["steps": .array(try await logs.attach(to: results, stepStarts: starts))] } catch {
            return ["steps": .array(results), "logsError": .string(error.localizedDescription)]
        }
    }

    private func doctor() async -> JSONValue {
        var report: [String: JSONValue] = [
            "developerDirectory": .string(tools.developerDirectory), "device": .string(device.name),
            "state": JSONValue(device.state), "deviceType": JSONValue(device.deviceTypeIdentifier),
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
            let backlights = try await self.device.backlights()
            guard !backlights.isEmpty else { return .unsupported }
            return .object(Dictionary(uniqueKeysWithValues: backlights.map { (String($0.key), JSONValue.string($0.value.rawValue)) }))
        }
        report["locked"] = await Self.check {
            .bool(try self.device.darwinNotificationState(Self.lockStateNotification) != 0)
        }
        report["accessibility"] = await Self.check { try await self.accessibility.doctorJSON() }
        report["appearance"] = await Self.check { try await self.settings.value(of: SettingCatalog.appearance) }
        report["posture"] = await Self.check {
            guard try await self.hinge.value() != nil else { return .unsupported }
            return try await self.readPosture()
        }
        return .object(report)
    }

    private static func check(_ probe: () async throws -> JSONValue) async -> JSONValue {
        do { return try await probe() } catch { return ["error": .string(error.localizedDescription)] }
    }

    private static func absolutePath(_ path: String, in workingDirectory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)).standardizedFileURL.path
    }
}
