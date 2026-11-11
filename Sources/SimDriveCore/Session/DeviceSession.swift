import AppKit
import Foundation
import SimDriveNative

/// One booted simulator's services, opened on first use. Inputs are released after a short idle period: an attached
/// keyboard changes how the guest behaves, and while simdrive holds the digitizer, the guest drops other clients' touches.
@MainActor
final class DeviceSession {
    private enum Timing {
        static let keyGap: Duration = .milliseconds(40)
        /// Presses closer together than this can read as one double or long press.
        static let repeatGap: Duration = .milliseconds(150)
        static let inputIdleRelease: Duration = .seconds(30)
    }

    private let udid: String
    private let device: SimulatorDevice
    private let tools: DeveloperTools
    private let guest: SimulatorGuest
    private let screens: ScreenTargets
    private let orientation: LazyCapability<GuestOrientation>
    private let pasteboard: LazyCapability<CoreDevicePasteboard>
    private let hinge: LazyCapability<Hinge>
    private var keyboardBindings: KeyboardBindings?
    private var keyboard: GuestKeyboard?
    private var touchscreen: GuestTouchscreen?
    private var buttons: GuestButtons?
    private var inputRelease: Task<Void, Never>?

    private init(udid: String, device: SimulatorDevice, tools: DeveloperTools, guest: SimulatorGuest) {
        self.udid = udid
        self.device = device
        self.tools = tools
        self.guest = guest
        let coreDevice = LazyCapability { try await CoreDeviceRemote.open(device: device) }
        let orientation = LazyCapability { try await GuestOrientation.open(guest: guest) }
        let hinge = LazyCapability<Hinge> {
            guard let remote = try await coreDevice.value() else { return nil }
            return try await Hinge.open(remote: remote)
        }
        pasteboard = LazyCapability { try await CoreDevicePasteboard.open(guest: guest, remote: { try await coreDevice.value() }) }
        self.orientation = orientation
        self.hinge = hinge
        screens = ScreenTargets(udid: udid, device: device, tools: tools, orientation: orientation, hinge: hinge)
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
            return try await setOrientation(orientation)
        case .orientation(nil):
            return try await readOrientation()
        case .pasteboard(let text?):
            return try await writePasteboard(text)
        case .pasteboard(nil):
            return try await readPasteboard()
        case .screenshot(let path, let display, let maxDimension):
            return try await screens.screenshot(to: Self.absolutePath(path, in: workingDirectory), display: display,
                                                maxDimension: maxDimension)
        case .launch(let bundleID, let arguments):
            return try await launch(bundleID, arguments: arguments)
        case .wait(let milliseconds):
            try await Task.sleep(for: .milliseconds(milliseconds))
            return ["waited": .number(Double(milliseconds))]
        case .run(let steps):
            return try await run(steps, workingDirectory: workingDirectory)
        case .doctor:
            return await doctor()
        case .stop, .serve:
            throw SimDriveError(.notADeviceCommand, "This command is handled by the command line, not a device session.")
        }
    }

    /// Closes every input connection, so the guest no longer counts a hardware keyboard and takes other clients' touches.
    /// The next command opens them again.
    func releaseInputs() async {
        inputRelease?.cancel()
        inputRelease = nil
        try? await keyboard?.close()
        await touchscreen?.close()
        await buttons?.close()
        keyboard = nil
        touchscreen = nil
        buttons = nil
    }

    func close() async {
        await releaseInputs()
        hinge.existing?.stop()
    }

    // MARK: Keyboard

    private func pressKey(_ name: String, modifiers: Set<KeyModifier>, count: Int) async throws -> JSONValue {
        guard let stroke = KeyMap.stroke(named: name) else { throw SimDriveError(.unknownKey, "Unknown key \(name).") }
        var flags = NSEvent.ModifierFlags(modifiers.map(\.flag))
        if stroke.needsShift { flags.insert(.shift) }
        let keyboard = try await connectedKeyboard()
        for index in 0..<count {
            if index > 0 { await pause(Timing.repeatGap) }
            try await keyboard.press(keyCode: stroke.keyCode, flags: flags)
        }
        scheduleInputRelease()
        return ["key": .string(name), "modifiers": .array(modifiers.map(\.rawValue).sorted().map(JSONValue.string)),
                "count": .number(Double(count))]
    }

    /// Types US-layout characters; other text goes through the pasteboard.
    private func type(_ text: String) async throws -> JSONValue {
        let strokes = try text.map { character in
            guard let stroke = KeyMap.stroke(for: character) else {
                throw SimDriveError(.unsupportedCharacter, "\"\(character)\" has no US-layout key.")
            }
            return stroke
        }
        let keyboard = try await connectedKeyboard()
        for stroke in strokes {
            try await keyboard.press(keyCode: stroke.keyCode, flags: stroke.needsShift ? .shift : [])
            await pause(Timing.keyGap)
        }
        scheduleInputRelease()
        return ["characters": .number(Double(text.count))]
    }

    private func connectedKeyboard() async throws -> GuestKeyboard {
        if let keyboard, !keyboard.hasFailed { return keyboard }
        let opened = try await GuestKeyboard.open(guest: guest, bindings: try await preparedKeyboardBindings())
        keyboard = opened
        return opened
    }

    private func preparedKeyboardBindings() async throws -> KeyboardBindings {
        if let keyboardBindings { return keyboardBindings }
        let prepared = try await KeyboardBindings()
        keyboardBindings = prepared
        return prepared
    }

    // MARK: Touches and buttons

    private func tap(_ point: ScreenPoint, display: DisplaySelector) async throws -> JSONValue {
        let target = try await screens.target(display, usesPixels: point.usesPixels)
        try await connectedTouchscreen().tap(at: target.digitizerPoint(point), target: target.digitizerTarget)
        scheduleInputRelease()
        return ["display": JSONValue(target.display?.index), "point": target.json(point)]
    }

    private func swipe(from start: ScreenPoint, to end: ScreenPoint, duration: Duration, edge: ScreenEdge?,
                       display: DisplaySelector) async throws -> JSONValue {
        let target = try await screens.target(display, usesPixels: start.usesPixels || end.usesPixels)
        try await connectedTouchscreen().drag(from: target.digitizerPoint(start), to: target.digitizerPoint(end),
            duration: duration, edge: edge.map(target.mapping.digitizerEdge), target: target.digitizerTarget)
        scheduleInputRelease()
        return ["display": JSONValue(target.display?.index), "from": target.json(start), "to": target.json(end),
                "edge": JSONValue(edge?.rawValue)]
    }

    private func press(_ button: HardwareButton, count: Int, hold: Duration) async throws -> JSONValue {
        let buttons = try await connectedButtons()
        for index in 0..<count {
            if index > 0 { await pause(Timing.repeatGap) }
            try await buttons.press(button, hold: hold)
        }
        if button == .home { screens.forgetScreenshots() }
        scheduleInputRelease()
        return ["button": .string(button.rawValue), "count": .number(Double(count))]
    }

    private func connectedTouchscreen() async throws -> GuestTouchscreen {
        if let touchscreen, !touchscreen.hasFailed { return touchscreen }
        let opened = try await GuestTouchscreen.open(guest: guest)
        touchscreen = opened
        return opened
    }

    private func connectedButtons() async throws -> GuestButtons {
        if let buttons, !buttons.hasFailed { return buttons }
        let opened = try await GuestButtons.open(guest: guest)
        buttons = opened
        return opened
    }

    // MARK: Orientation, pasteboard and posture

    private func readOrientation() async throws -> JSONValue {
        Self.json(try await connectedOrientation().read())
    }

    private func setOrientation(_ target: DeviceOrientation) async throws -> JSONValue {
        Self.json(try await connectedOrientation().set(target))
    }

    private func connectedOrientation() async throws -> GuestOrientation {
        guard let control = try await orientation.value() else {
            throw SimDriveError(.orientationUnsupported, "\(device.name) cannot rotate.")
        }
        return control
    }

    private static func json(_ reading: GuestOrientationReading) -> JSONValue {
        ["orientation": JSONValue(reading.orientation?.name),
         "physical": .string(DeviceOrientation(rawValue: reading.physical)?.name ?? reading.physical)]
    }

    private func readPasteboard() async throws -> JSONValue {
        let items = try await connectedPasteboard().read()
        return ["items": .array(items.map { ["types": .array($0.types.map(JSONValue.string)), "text": JSONValue($0.text)] })]
    }

    private func writePasteboard(_ text: String) async throws -> JSONValue {
        try await connectedPasteboard().write(text: text)
        return ["characters": .number(Double(text.count))]
    }

    private func connectedPasteboard() async throws -> CoreDevicePasteboard {
        guard let pasteboard = try await pasteboard.value() else {
            throw SimDriveError(.pasteboardUnsupported, "\(device.name) has no pasteboard.")
        }
        return pasteboard
    }

    private func readPosture() async throws -> JSONValue {
        let hinge = try await connectedHinge()
        try await hinge.waitForReading()
        return Self.json(hinge)
    }

    private func setPosture(_ posture: DevicePosture) async throws -> JSONValue {
        let hinge = try await connectedHinge()
        try await hinge.set(posture)
        return Self.json(hinge)
    }

    private func connectedHinge() async throws -> Hinge {
        guard let hinge = try await hinge.value() else {
            throw SimDriveError(.postureUnsupported, "\(device.name) has no hinge.")
        }
        return hinge
    }

    private static func json(_ hinge: Hinge) -> JSONValue {
        ["angle": JSONValue(hinge.angle), "posture": JSONValue(hinge.posture?.rawValue)]
    }

    // MARK: Apps, steps and diagnostics

    private func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue {
        // Restarts a running app, so it starts from its launch screen with these arguments.
        let result = try await tools.simctl(["launch", "--terminate-running-process", udid, bundleID] + arguments)
        screens.forgetScreenshots()
        let pid = result.standardOutput.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return ["bundleID": .string(bundleID), "pid": JSONValue(pid)]
    }

    private func run(_ steps: [[String]], workingDirectory: String) async throws -> JSONValue {
        let commands = try steps.enumerated().map { index, step in
            let command: Command
            do { command = try CommandParser.parse(step) } catch {
                throw SimDriveError(.stepInvalid, "Step \(index + 1) (\(step.joined(separator: " "))): \(error.localizedDescription)")
            }
            guard command.isStep else { throw SimDriveError(.stepInvalid, "Step \(index + 1) cannot be \(step.first ?? "")") }
            return command
        }
        var results: [JSONValue] = []
        for (index, command) in commands.enumerated() {
            do { results.append(try await execute(command, workingDirectory: workingDirectory)) } catch {
                throw SimDriveError(.stepFailed, "Step \(index + 1) (\(steps[index].joined(separator: " "))) failed after \(index) completed: \(error.localizedDescription)")
            }
        }
        return ["steps": .array(results)]
    }

    private func doctor() async -> JSONValue {
        var report: [String: JSONValue] = [
            "developerDirectory": .string(tools.developerDirectory), "device": .string(device.name),
            "state": JSONValue(device.state), "deviceType": JSONValue(device.deviceTypeIdentifier),
        ]
        report["orientation"] = await Self.check {
            guard try await self.orientation.value() != nil else { return "unsupported" }
            return .string(try await self.screens.currentOrientation().name)
        }
        report["pasteboard"] = await Self.check { try await self.pasteboard.value() == nil ? "unsupported" : "ready" }
        report["keyboard"] = await Self.check {
            _ = try await self.preparedKeyboardBindings()
            return "ready"
        }
        report["displays"] = await Self.check { try await self.screens.displaysJSON() }
        report["posture"] = await Self.check {
            guard try await self.hinge.value() != nil else { return "unsupported" }
            return try await self.readPosture()
        }
        return .object(report)
    }

    private static func check(_ probe: () async throws -> JSONValue) async -> JSONValue {
        do { return try await probe() } catch { return ["error": .string(error.localizedDescription)] }
    }

    private func scheduleInputRelease() {
        inputRelease?.cancel()
        inputRelease = Task { [weak self] in
            try? await Task.sleep(for: Timing.inputIdleRelease)
            guard !Task.isCancelled else { return }
            await self?.releaseInputs()
        }
    }

    /// Sleeps without throwing, so a sequence of presses always completes.
    private func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    private static func absolutePath(_ path: String, in workingDirectory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)).standardizedFileURL.path
    }
}
