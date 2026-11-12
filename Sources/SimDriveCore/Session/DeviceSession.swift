import AppKit
import Foundation
import SimDriveNative

/// One booted simulator's services, opened on first use. Each command runs here and returns its JSON result.
@MainActor
final class DeviceSession {
    /// How long an app may take to come to the front after `simctl launch`, which returns seconds before it does. A
    /// freshly booted, busy simulator takes tens of seconds.
    private static let launchLimit: Duration = .seconds(30)

    private let udid: String
    private let device: SimulatorDevice
    private let tools: DeveloperTools
    private let inputs: DeviceInputs
    private let screens: Screens
    private let accessibility: DeviceAccessibility
    private let settings: DeviceSettings
    private let logs: DeviceLogs
    private let orientation: LazyCapability<GuestOrientation>
    private let pasteboard: LazyCapability<CoreDevicePasteboard>
    private let hinge: LazyCapability<Hinge>

    private init(udid: String, device: SimulatorDevice, tools: DeveloperTools, guest: SimulatorGuest) {
        self.udid = udid
        self.device = device
        self.tools = tools
        let coreDevice = LazyCapability { try await CoreDeviceRemote.open(device: device) }
        let orientation = LazyCapability(isUsable: { !$0.hasFailed }) { try await GuestOrientation.open(guest: guest) }
        let hinge = LazyCapability<Hinge>(close: { $0.stop() }) {
            guard let remote = try await coreDevice.value() else { return nil }
            return try await Hinge.open(remote: remote)
        }
        pasteboard = LazyCapability { try await CoreDevicePasteboard.open(guest: guest, remote: { try await coreDevice.value() }) }
        self.orientation = orientation
        self.hinge = hinge
        inputs = DeviceInputs(guest: guest)
        screens = Screens(udid: udid, device: device, tools: tools, orientation: orientation, hinge: hinge)
        accessibility = DeviceAccessibility(device: device, screens: screens)
        settings = DeviceSettings(udid: udid, device: device, tools: tools)
        logs = DeviceLogs(udid: udid, tools: tools)
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

    func execute(_ command: Command, workingDirectory: String) async throws -> JSONValue {
        switch command {
        case .key(let name, let modifiers, let count):
            return try await pressKey(name, modifiers: modifiers, count: count)
        case .type(let text):
            return try await type(text)
        case .tap(let point, let display):
            return try await tap(point, display: display)
        case .swipe(let start, let end, let duration, let edge, let display):
            return try await swipe(from: start, to: end, duration: duration, edge: edge, display: display)
        case .button(let button, let count, let hold):
            return try await press(button, count: count, hold: hold)
        case .posture(let posture?):
            return try await setPosture(posture)
        case .posture(nil):
            return try await readPosture()
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
            return try await accessibility.element(at: point, detail: detail)
        case .tree(nil, let detail):
            return try await accessibility.tree(detail: detail)
        case .setting(let setting?, let value?):
            return try await settings.set(setting, to: value)
        case .setting(let setting?, nil):
            return try await settings.read(setting)
        case .setting(nil, _):
            return try await settings.all()
        case .launch(let bundleID, let arguments):
            return try await launch(bundleID, arguments: arguments)
        case .wait(let milliseconds):
            try await Task.sleep(for: .milliseconds(milliseconds))
            return ["waited": JSONValue(milliseconds)]
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

    /// Types US-layout characters; other text goes through the pasteboard.
    private func type(_ text: String) async throws -> JSONValue {
        let strokes = try text.map { character in
            guard let stroke = KeyMap.stroke(for: character) else {
                throw SimDriveError(.unsupportedCharacter, "\"\(character)\" has no US-layout key.")
            }
            return stroke
        }
        try await inputs.type(strokes)
        return ["characters": JSONValue(text.count)]
    }

    // MARK: Touches and buttons

    private func tap(_ point: ScreenPoint, display: DisplaySelector) async throws -> JSONValue {
        let screen = try await screens.touchscreen(display, usesPixels: point.usesPixels)
        try await inputs.tap(at: screen.digitizerPoint(point), on: screen.digitizerTarget)
        return ["display": JSONValue(screen.display?.index), "point": screen.json(point)]
    }

    private func swipe(from start: ScreenPoint, to end: ScreenPoint, duration: Duration, edge: ScreenEdge?,
                       display: DisplaySelector) async throws -> JSONValue {
        let screen = try await screens.touchscreen(display, usesPixels: start.usesPixels || end.usesPixels)
        try await inputs.drag(from: screen.digitizerPoint(start), to: screen.digitizerPoint(end), duration: duration,
                              edge: edge.map(screen.mapping.digitizerEdge), on: screen.digitizerTarget)
        return ["display": JSONValue(screen.display?.index), "from": screen.json(start), "to": screen.json(end),
                "edge": JSONValue(edge?.rawValue)]
    }

    private func press(_ button: HardwareButton, count: Int, hold: Duration) async throws -> JSONValue {
        try await inputs.press(button, count: count, hold: hold)
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
        try await hinge.set(posture)
        return hinge.json
    }

    private func connectedHinge() async throws -> Hinge {
        try await hinge.required(orThrow: SimDriveError(.postureUnsupported, "\(device.name) has no hinge."))
    }

    // MARK: Apps, steps and diagnostics

    private func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue {
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
                throw SimDriveError(.stepFailed, "Step \(index + 1) (\(step.arguments.joined(separator: " "))) failed after \(index) "
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
