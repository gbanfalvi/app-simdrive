import AppKit
import Foundation
import SimDriveNative

/// One booted simulator's input services, opened on first use. Guest input is released after a short idle period,
/// since an attached hardware keyboard changes how the guest behaves.
@MainActor
package final class DeviceSession {
    private enum Timing {
        static let keyHold: Duration = .milliseconds(40)
        static let keyGap: Duration = .milliseconds(40)
        static let repeatGap: Duration = .milliseconds(150)
        static let tapHold: Duration = .milliseconds(60)
        static let swipeStep: Duration = .milliseconds(16)
        /// The guest matches a new input service shortly after creating it and drops events sent before.
        static let inputSettle: Duration = .milliseconds(400)
        /// The guest drops the events of a connection that ends before it has activated it.
        static let inputDrain: Duration = .milliseconds(500)
        static let inputIdleRelease: Duration = .seconds(30)
        static let postureLimit: Duration = .seconds(15)
        static let anglePoll: Duration = .milliseconds(100)
        static let hingeSettle: Duration = .milliseconds(400)
    }

    private enum PostureState {
        case unknown, unsupported
        case available(PostureTransport, observation: Task<Void, Never>)
    }

    private enum Availability<Service> {
        case unknown, unsupported
        case available(Service)
    }

    /// The touch target and store key of a single-screen device.
    private nonisolated static let mainScreen = "mainScreen"

    package let udid: String
    private let device: SimulatorDevice
    private let tools: ToolRunner
    private let guest: SimulatorGuestHID
    private let screens: ScreenStore
    private var keyboardBindings: KeyboardBindings?
    private var keyboard: GuestKeyboard?
    private var touchscreen: GuestTouchscreen?
    private var buttons: GuestButtons?
    private var orientationControl = Availability<GuestDeviceOrientation>.unknown
    private var devicePasteboard = Availability<DevicePasteboard>.unknown
    private var posture = PostureState.unknown
    private var hingeAngle: Double?
    private var displays: [DisplayInfo]?
    private var releaseTask: Task<Void, Never>?

    private init(udid: String, device: SimulatorDevice, tools: ToolRunner, guest: SimulatorGuestHID) {
        self.udid = udid
        self.device = device
        self.tools = tools
        self.guest = guest
        screens = ScreenStore(url: DaemonPaths.screens(for: udid))
    }

    package static func open(udid: String, tools: ToolRunner) async throws -> DeviceSession {
        let device = try SimulatorDevice.find(udid: udid, developerDirectory: tools.developerDirectory)
        guard device.isBooted else {
            throw SimDriveError("not-booted", "\(device.name) is \(device.state ?? "not booted"); boot it first.")
        }
        let guest = try await SimulatorGuestHID(lookUp: { try device.lookUp($0) })
        try DaemonPaths.prepare()
        return DeviceSession(udid: udid, device: device, tools: tools, guest: guest)
    }

    package func execute(_ command: Command, workingDirectory: String) async throws -> JSONValue {
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
        case .posture(let target):
            return try await setPosture(target)
        case .orientation(let target):
            return try await setOrientation(target)
        case .pasteboard(let text):
            return try await pasteboard(text)
        case .screenshot(let path, let display, let maxDimension):
            return try await screenshot(to: Self.absolutePath(path, in: workingDirectory), display: display, maxDimension: maxDimension)
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
            throw SimDriveError("not-a-device-command", "This command is handled by the command line, not a device session.")
        }
    }

    /// Removes the guest's input services, so it no longer counts a hardware keyboard.
    package func releaseInputs() async {
        releaseTask?.cancel()
        releaseTask = nil
        if let keyboard { try? await keyboard.stop() }
        if let touchscreen { try? await touchscreen.flush() }
        if let buttons { try? await buttons.flush() }
        keyboard = nil
        touchscreen = nil
        buttons = nil
    }

    package func close() async {
        if touchscreen != nil || buttons != nil { await pause(Timing.inputDrain) }
        await releaseInputs()
        if case .available(_, let observation) = posture { observation.cancel() }
        posture = .unknown
    }

    // MARK: Keyboard

    private func pressKey(_ name: String, modifiers: Set<KeyModifier>, count: Int) async throws -> JSONValue {
        guard let stroke = KeyMap.stroke(named: name) else { throw SimDriveError("unknown-key", "Unknown key \(name).") }
        var flags = NSEvent.ModifierFlags(modifiers.map(\.flag))
        if stroke.shift { flags.insert(.shift) }
        let keyboard = try await connectedKeyboard()
        for index in 0..<count {
            if index > 0 { await pause(Timing.repeatGap) }
            try await strike(stroke.keyCode, flags: flags, on: keyboard)
        }
        scheduleInputRelease()
        return ["key": .string(name), "modifiers": .array(modifiers.map(\.rawValue).sorted().map(JSONValue.string)),
                "count": .number(Double(count))]
    }

    /// Types US-layout characters; other text goes through the pasteboard.
    private func type(_ text: String) async throws -> JSONValue {
        let strokes = try text.map { character in
            guard let stroke = KeyMap.stroke(for: character) else {
                throw SimDriveError("unsupported-character", "\"\(character)\" has no US-layout key.")
            }
            return stroke
        }
        let keyboard = try await connectedKeyboard()
        for stroke in strokes {
            try await strike(stroke.keyCode, flags: stroke.shift ? .shift : [], on: keyboard)
            await pause(Timing.keyGap)
        }
        scheduleInputRelease()
        return ["characters": .number(Double(text.count))]
    }

    private func strike(_ keyCode: UInt16, flags: NSEvent.ModifierFlags, on keyboard: GuestKeyboard) async throws {
        if !flags.isEmpty { try await keyboard.setModifiers(flags) }
        try await keyboard.keyDown(keyCode, flags: flags)
        await pause(Timing.keyHold)
        try await keyboard.keyUp(keyCode, flags: flags)
        if !flags.isEmpty { try await keyboard.setModifiers([]) }
    }

    private func connectedKeyboard() async throws -> GuestKeyboard {
        if let keyboard, !keyboard.hasFailed { return keyboard }
        if keyboardBindings == nil { keyboardBindings = try await KeyboardBindings() }
        guard let keyboardBindings else { throw SimDriveError("keyboard", "The keyboard bindings are unavailable.") }
        let created = try await GuestKeyboard(guest: guest, bindings: keyboardBindings)
        try await created.attach()
        await pause(Timing.inputSettle)
        keyboard = created
        return created
    }

    // MARK: Touches and buttons

    private struct ScreenTarget {
        let display: DisplayInfo?
        let record: ScreenRecord
        let mapping: ScreenMapping

        var digitizerTarget: String { display?.digitizerTarget ?? DeviceSession.mainScreen }

        func screenUnitPoint(_ point: ScreenPoint) -> CGPoint {
            let unit = switch point {
            case .unit(let value): value
            case .pixels(let value): CGPoint(x: value.x / CGFloat(record.imageWidth), y: value.y / CGFloat(record.imageHeight))
            }
            return CGPoint(x: min(max(unit.x, 0), 1), y: min(max(unit.y, 0), 1))
        }

        func digitizerPoint(_ point: ScreenPoint) -> CGPoint { mapping.digitizerPoint(screenUnitPoint(point)) }

        func json(_ point: ScreenPoint) -> JSONValue {
            let unit = screenUnitPoint(point)
            return ["x": .number(unit.x), "y": .number(unit.y)]
        }
    }

    private func tap(_ point: ScreenPoint, display: DisplaySelector) async throws -> JSONValue {
        let target = try await screenTarget(display, usesPixels: point.usesPixels)
        let location = target.digitizerPoint(point)
        let touchscreen = try await connectedTouchscreen()
        try touchscreen.send(location, phase: .began, edge: .none, target: target.digitizerTarget)
        await pause(Timing.tapHold)
        try touchscreen.send(location, phase: .ended, edge: .none, target: target.digitizerTarget)
        try await touchscreen.flush()
        scheduleInputRelease()
        return ["display": JSONValue(target.display?.index), "point": target.json(point)]
    }

    private func swipe(from start: ScreenPoint, to end: ScreenPoint, duration: Duration, edge: ScreenEdge?,
                       display: DisplaySelector) async throws -> JSONValue {
        let target = try await screenTarget(display, usesPixels: start.usesPixels || end.usesPixels)
        let touchEdge = edge.map { Self.touchEdge(target.mapping.digitizerEdge($0)) } ?? .none
        let from = target.digitizerPoint(start)
        let to = target.digitizerPoint(end)
        let steps = max(1, Int((duration / Timing.swipeStep).rounded()))
        let touchscreen = try await connectedTouchscreen()
        try touchscreen.send(from, phase: .began, edge: touchEdge, target: target.digitizerTarget)
        for step in 1...steps {
            await pause(Timing.swipeStep)
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
            try touchscreen.send(point, phase: .moved, edge: touchEdge, target: target.digitizerTarget)
        }
        try touchscreen.send(to, phase: .ended, edge: touchEdge, target: target.digitizerTarget)
        try await touchscreen.flush()
        scheduleInputRelease()
        return ["display": JSONValue(target.display?.index), "from": target.json(start), "to": target.json(end),
                "edge": JSONValue(edge?.rawValue)]
    }

    private func press(_ button: HardwareButton, count: Int, hold: Duration) async throws -> JSONValue {
        let buttons = try await connectedButtons()
        for index in 0..<count {
            if index > 0 { await pause(Timing.repeatGap) }
            try buttons.send(usagePage: HardwareButton.usagePage, usage: button.usage, state: .down)
            await pause(hold)
            try buttons.send(usagePage: HardwareButton.usagePage, usage: button.usage, state: .up)
        }
        try await buttons.flush()
        if button == .home { screens.removeAll() }
        scheduleInputRelease()
        return ["button": .string(button.rawValue), "count": .number(Double(count))]
    }

    /// The display a point refers to, with the rotation of its last screenshot. Unit points take a calibration
    /// screenshot when there is none for the current orientation; pixel points need the caller's own.
    private func screenTarget(_ selector: DisplaySelector, usesPixels: Bool) async throws -> ScreenTarget {
        guard device.hasTouchscreen else {
            throw SimDriveError("no-touchscreen", "\(device.name) has no touchscreen; use button or key to move focus.")
        }
        let display = try await resolveDisplay(selector)
        let key = display?.digitizerTarget ?? Self.mainScreen
        let orientation = try await currentOrientation()
        var record = screens.record(for: key)
        if let existing = record, existing.orientation != orientation {
            guard !usesPixels else {
                throw SimDriveError("stale-screenshot", "The device rotated since the last screenshot; take a new one.")
            }
            record = nil
        }
        if record == nil {
            guard !usesPixels else {
                throw SimDriveError("no-screenshot", "Pixel coordinates refer to the last screenshot; take one, or pass fractions such as 0.5 0.5.")
            }
            record = try await calibrate(display: display, key: key, orientation: orientation)
        }
        guard let record else { throw SimDriveError("no-screenshot", "No screenshot describes this screen.") }
        let isRotated = record.isLandscape != (display?.isNativeLandscape ?? false)
        return ScreenTarget(display: display, record: record, mapping: ScreenMapping(isRotated: isRotated, orientation: orientation))
    }

    private func calibrate(display: DisplayInfo?, key: String, orientation: DeviceOrientation) async throws -> ScreenRecord {
        let shot = try await Screenshots.capture(udid: udid, display: display?.index,
            to: DaemonPaths.calibration(for: udid).path, maxDimension: 0, tools: tools)
        let record = ScreenRecord(width: shot.fullWidth, height: shot.fullHeight, imageWidth: shot.width,
                                  imageHeight: shot.height, orientation: orientation)
        screens.save(record, for: key)
        return record
    }

    private func connectedTouchscreen() async throws -> GuestTouchscreen {
        if let touchscreen, !touchscreen.hasFailed { return touchscreen }
        let created = try await GuestTouchscreen(guest: guest)
        await pause(Timing.inputSettle)
        touchscreen = created
        return created
    }

    private func connectedButtons() async throws -> GuestButtons {
        if let buttons, !buttons.hasFailed { return buttons }
        let created = try await GuestButtons(guest: guest)
        await pause(Timing.inputSettle)
        buttons = created
        return created
    }

    private static func touchEdge(_ edge: ScreenEdge) -> TouchEdge {
        switch edge {
        case .top: .top
        case .bottom: .bottom
        case .left: .left
        case .right: .right
        }
    }

    // MARK: Displays, orientation and posture

    private func knownDisplays() async throws -> [DisplayInfo] {
        if let displays { return displays }
        // A multi-display device refuses a screenshot without --display and lists its displays instead.
        let probe = DaemonPaths.calibration(for: udid).path
        let result = try await tools.simctl(["io", udid, "screenshot", "--type=png", probe])
        try? FileManager.default.removeItem(atPath: probe)
        if result.succeeded {
            displays = []
            return []
        }
        let found = DisplayInfo.parse(listing: result.output + "\n" + result.errorOutput)
        guard !found.isEmpty else { throw SimDriveError("screenshot", "simctl could not capture the screen: \(result.diagnostics)") }
        displays = found
        return found
    }

    private func resolveDisplay(_ selector: DisplaySelector) async throws -> DisplayInfo? {
        let displays = try await knownDisplays()
        guard !displays.isEmpty else {
            guard selector == .automatic else { throw SimDriveError("single-display", "\(device.name) has one display.") }
            return nil
        }
        switch selector {
        case .index(let index):
            guard let display = displays.first(where: { $0.index == index }) else {
                throw SimDriveError("unknown-display", "\(device.name) has no display \(index).")
            }
            return display
        case .cover:
            return try display(role: DisplayInfo.coverRole, in: displays)
        case .inner:
            return try display(role: DisplayInfo.innerRole, in: displays)
        case .automatic:
            let role = try await isClosed() ? DisplayInfo.coverRole : DisplayInfo.innerRole
            return displays.first { $0.role == role } ?? displays[0]
        }
    }

    private func display(role: String, in displays: [DisplayInfo]) throws -> DisplayInfo {
        guard let display = displays.first(where: { $0.role == role }) else {
            throw SimDriveError("unknown-display", "\(device.name) has no \(role) display.")
        }
        return display
    }

    /// Whether a foldable is closed; a device without a hinge counts as closed, showing its primary display.
    private func isClosed() async throws -> Bool {
        guard try await postureTransport() != nil else { return true }
        try await waitForAngle { $0 != nil }
        return DevicePosture.confirmed(angle: hingeAngle) == .closed
    }

    /// A device that cannot rotate, such as an Apple TV, counts as portrait.
    private func currentOrientation() async throws -> DeviceOrientation {
        guard let control = try await orientation() else { return .portrait }
        return DeviceOrientation(rawValue: try await control.read().nonFlat) ?? .portrait
    }

    private func orientation() async throws -> GuestDeviceOrientation? {
        switch orientationControl {
        case .available(let control):
            return control
        case .unsupported:
            return nil
        case .unknown:
            let control = try await GuestDeviceOrientation.open(guest: guest)
            orientationControl = control.map { .available($0) } ?? .unsupported
            return control
        }
    }

    private func setOrientation(_ target: DeviceOrientation?) async throws -> JSONValue {
        guard let control = try await orientation() else {
            throw SimDriveError("orientation-unsupported", "\(device.name) cannot rotate.")
        }
        let reading = if let target { try await control.set(named: target.rawValue) } else { try await control.read() }
        return ["orientation": .string(reading.nonFlat), "physical": .string(reading.physical)]
    }

    // MARK: Pasteboard

    private func pasteboard(_ text: String?) async throws -> JSONValue {
        guard let pasteboard = try await connectedPasteboard() else {
            throw SimDriveError("pasteboard-unsupported", "\(device.name) has no pasteboard.")
        }
        if let text {
            try await pasteboard.write(text: text)
            return ["characters": .number(Double(text.count))]
        }
        let items = try await pasteboard.read()
        return ["items": .array(items.map { ["types": .array($0.types.map(JSONValue.string)), "text": JSONValue($0.text)] })]
    }

    private func connectedPasteboard() async throws -> DevicePasteboard? {
        switch devicePasteboard {
        case .available(let pasteboard):
            return pasteboard
        case .unsupported:
            return nil
        case .unknown:
            let pasteboard = try await DevicePasteboard.make(device: device)
            devicePasteboard = pasteboard.map { .available($0) } ?? .unsupported
            return pasteboard
        }
    }

    private func postureTransport() async throws -> PostureTransport? {
        switch posture {
        case .unsupported:
            return nil
        case .available(let transport, _):
            return transport
        case .unknown:
            guard let transport = try await PostureTransport.make(udid: udid) else {
                posture = .unsupported
                return nil
            }
            let observation = Task { [weak self] in
                do {
                    try await transport.observe { self?.hingeAngle = $0 }
                } catch {
                    self?.hingeAngle = nil
                }
                self?.posture = .unknown
            }
            posture = .available(transport, observation: observation)
            return transport
        }
    }

    private func setPosture(_ target: DevicePosture?) async throws -> JSONValue {
        guard let transport = try await postureTransport() else {
            throw SimDriveError("posture-unsupported", "\(device.name) has no hinge.")
        }
        if let target {
            try await transport.send(target)
            try await waitForAngle { DevicePosture.confirmed(angle: $0) == target }
            try await waitForSettledAngle()
        } else {
            try await waitForAngle { $0 != nil }
        }
        return ["angle": JSONValue(hingeAngle), "posture": JSONValue(DevicePosture.confirmed(angle: hingeAngle)?.rawValue)]
    }

    /// Waits for the hinge animation to end, which settles near but not at the requested angle.
    private func waitForSettledAngle() async throws {
        let deadline = ContinuousClock.now + Timing.postureLimit
        var settledSince = ContinuousClock.now
        var lastAngle = hingeAngle
        while ContinuousClock.now - settledSince < Timing.hingeSettle {
            guard ContinuousClock.now < deadline else {
                throw SimDriveError("posture-timeout", "The hinge kept moving; it reads \(hingeAngle.map { "\($0)" } ?? "nothing").")
            }
            try await Task.sleep(for: Timing.anglePoll)
            if hingeAngle != lastAngle {
                lastAngle = hingeAngle
                settledSince = .now
            }
        }
    }

    private func waitForAngle(until condition: (Double?) -> Bool) async throws {
        let deadline = ContinuousClock.now + Timing.postureLimit
        while !condition(hingeAngle) {
            guard ContinuousClock.now < deadline else {
                throw SimDriveError("posture-timeout", "The hinge did not report the expected angle; it reads \(hingeAngle.map { "\($0)" } ?? "nothing").")
            }
            try await Task.sleep(for: Timing.anglePoll)
        }
    }

    // MARK: Screenshots, apps, steps

    private func screenshot(to path: String, display selector: DisplaySelector, maxDimension: Int) async throws -> JSONValue {
        let display = try await resolveDisplay(selector)
        let orientation = try await currentOrientation()
        let canRotate = try await self.orientation() != nil
        let shot = try await Screenshots.capture(udid: udid, display: display?.index, to: path, maxDimension: maxDimension, tools: tools)
        screens.save(ScreenRecord(width: shot.fullWidth, height: shot.fullHeight, imageWidth: shot.width,
                                  imageHeight: shot.height, orientation: orientation),
                     for: display?.digitizerTarget ?? Self.mainScreen)
        return ["path": .string(shot.path), "width": .number(Double(shot.width)), "height": .number(Double(shot.height)),
                "fullPath": .string(shot.fullPath), "fullWidth": .number(Double(shot.fullWidth)),
                "fullHeight": .number(Double(shot.fullHeight)), "display": JSONValue(display?.index),
                "orientation": canRotate ? .string(orientation.rawValue) : .null]
    }

    private func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue {
        let result = try await tools.checkedSimctl(["launch", "--terminate-running-process", udid, bundleID] + arguments)
        screens.removeAll()
        let pid = result.output.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return ["bundleID": .string(bundleID), "pid": JSONValue(pid)]
    }

    private func run(_ steps: [[String]], workingDirectory: String) async throws -> JSONValue {
        let commands = try steps.enumerated().map { index, step in
            let command: Command
            do { command = try CommandParser.parse(step) } catch {
                throw SimDriveError("step-invalid", "Step \(index + 1) (\(step.joined(separator: " "))): \(error.localizedDescription)")
            }
            guard command.isStep else { throw SimDriveError("step-invalid", "Step \(index + 1) cannot be \(step.first ?? "")") }
            return command
        }
        var results: [JSONValue] = []
        for (index, command) in commands.enumerated() {
            do { results.append(try await execute(command, workingDirectory: workingDirectory)) } catch {
                throw SimDriveError("step-failed", "Step \(index + 1) (\(steps[index].joined(separator: " "))) failed after \(index) completed: \(error.localizedDescription)")
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
            guard try await self.orientation() != nil else { return "unsupported" }
            return .string(try await self.currentOrientation().rawValue)
        }
        report["pasteboard"] = await Self.check { try await self.connectedPasteboard() == nil ? "unsupported" : "ready" }
        report["keyboard"] = await Self.check {
            if self.keyboardBindings == nil { self.keyboardBindings = try await KeyboardBindings() }
            return "ready"
        }
        report["displays"] = await Self.check { .array(try await self.knownDisplays().map(\.json)) }
        report["posture"] = await Self.check {
            guard try await self.postureTransport() != nil else { return "unsupported" }
            return try await self.setPosture(nil)
        }
        return .object(report)
    }

    private static func check(_ probe: () async throws -> JSONValue) async -> JSONValue {
        do { return try await probe() } catch { return ["error": .string(error.localizedDescription)] }
    }

    // MARK: Helpers

    private func scheduleInputRelease() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: Timing.inputIdleRelease)
            guard !Task.isCancelled else { return }
            await self?.releaseInputs()
        }
    }

    /// Sleeps without throwing, so a held key or touch is always released.
    private func pause(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    private static func absolutePath(_ path: String, in workingDirectory: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true)).standardizedFileURL.path
    }
}
