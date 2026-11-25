import CoreGraphics
import Foundation
import SimDriveNative

/// Where points land: the device's displays, each screen's last screenshot, and how its points map to the digitizer.
@MainActor
final class Screens {
    /// A calibration screenshot keeps its full resolution.
    private static let fullResolution = 0
    /// The screen ID CoreSimulator gives a single-display device's screen.
    private static let mainScreenID = 1
    /// Bounds the orientation a screenshot records, which the guest takes seconds to report after boot.
    private static let screenshotOrientationLimit: Duration = .seconds(1)
    /// A system alert draws nothing for ~120 ms after the tree can show it, so stillness must outlast that (F29).
    private static let settleStillFor: Duration = .milliseconds(150)
    /// Bounds the wait for content that keeps moving, such as a spinner; the tap goes ahead after it.
    private static let settleLimit: Duration = .milliseconds(1500)
    private static let settleInterval: Duration = .milliseconds(25)
    /// In points: a fingertip's target, Apple's minimum touch size.
    private static let settlePatch = 44.0
    private static let fallbackScale = 3.0

    private let udid: String
    private let device: SimulatorDevice
    private let tools: DeveloperTools
    private let orientation: LazyCapability<GuestOrientation>
    private let hinge: LazyCapability<Hinge>
    private let store: ScreenStore

    init(udid: String, device: SimulatorDevice, tools: DeveloperTools, orientation: LazyCapability<GuestOrientation>,
         hinge: LazyCapability<Hinge>) {
        self.udid = udid
        self.device = device
        self.tools = tools
        self.orientation = orientation
        self.hinge = hinge
        store = ScreenStore(url: StatePaths.screens(for: udid), bootedAt: device.lastBootedAt)
    }

    /// The touchscreen display a point refers to.
    func touchscreen(_ selector: DisplaySelector, usesPixels: Bool) async throws -> Screen {
        guard device.hasTouchscreen else {
            throw SimDriveError(.noTouchscreen, "\(device.name) has no touchscreen; use button or key to move focus.")
        }
        return try await screen(selector, usesPixels: usesPixels)
    }

    /// The display a point refers to, with the rotation of its last screenshot. Fractions take a calibration
    /// screenshot when there is none for the current orientation; pixels need the caller's own.
    func screen(_ selector: DisplaySelector, usesPixels: Bool) async throws -> Screen {
        let display = try await display(for: selector)
        let orientation = await knownDeviceOrientation() ?? .portrait
        var record = store.record(for: DigitizerTarget(display: display))
        if let existing = record,
           !existing.isCurrent(deviceOrientation: orientation, interfaceOrientation: await interfaceOrientation(of: display)) {
            guard !usesPixels else {
                throw SimDriveError(.staleScreenshot, "The device or its interface rotated since the last screenshot; take a new one.")
            }
            record = nil
        }
        let current: ScreenshotRecord
        if let record {
            current = record
        } else {
            guard !usesPixels else {
                throw SimDriveError(.noScreenshot, "Pixel coordinates refer to the last screenshot; take one, or pass fractions such as 0.5 0.5.")
            }
            current = try await calibrate(display, orientation: orientation)
        }
        // Single touchscreens are portrait natively, and TVs landscape.
        let mapping = ScreenMapping(screenshot: current, panelIsLandscape: display?.nativeSize.isLandscape ?? !device.hasTouchscreen,
                                    deviceOrientation: orientation)
        return Screen(display: display, record: current, mapping: mapping)
    }

    func screenshot(to path: String, display selector: DisplaySelector, maxDimension: Int) async throws -> JSONValue {
        let display = try await display(for: selector)
        let orientation = await knownDeviceOrientation(within: Self.screenshotOrientationLimit)
        let (shot, _) = try await capture(display, to: path, maxDimension: maxDimension, orientation: orientation ?? .portrait)
        return shot.json(display: display, orientation: orientation)
    }

    /// Waits until the pixels around a point have held still for `settleStillFor`, or for `settleLimit` at most, and
    /// returns how long it waited and whether they did; nil when the screen's pixels cannot be read.
    func settle(around point: ScreenPoint, on screen: Screen) async throws -> (waited: Duration, still: Bool)? {
        let screenID = screen.display?.index ?? Self.mainScreenID
        let unitPoint = screen.digitizerPoint(point)
        let side = Int((Self.settlePatch * (device.screenScale ?? Self.fallbackScale)).rounded())
        var stillness = Stillness(stillFor: Self.settleStillFor)
        let start = ContinuousClock.now
        while true {
            guard let sample = device.screenPixels(screenID: screenID, around: unitPoint, side: side) else { return nil }
            let elapsed = ContinuousClock.now - start
            if stillness.isStill(after: sample, at: elapsed) { return (elapsed, true) }
            if elapsed >= Self.settleLimit { return (elapsed, false) }
            try await Task.sleep(for: Self.settleInterval)
        }
    }

    /// Forgets every screenshot, since a new foreground app may rotate the interface without rotating the device.
    func forgetScreenshots() {
        store.removeRecords()
    }

    func displaysJSON() async throws -> JSONValue {
        .array(try await displays().map(\.json))
    }

    /// Nil when the device cannot rotate, as an Apple TV; screens then count as portrait.
    func deviceOrientation() async throws -> DeviceOrientation? {
        guard let control = try await orientation.value() else { return nil }
        return try await control.read().orientation ?? .portrait
    }

    /// Nil also when the guest does not answer, as right after boot, so screens degrade to portrait instead of failing.
    private func knownDeviceOrientation() async -> DeviceOrientation? {
        try? await deviceOrientation()
    }

    /// As `knownDeviceOrientation()`, but nil past `limit`; the read goes on, so later commands get it sooner.
    private func knownDeviceOrientation(within limit: Duration) async -> DeviceOrientation? {
        let (first, continuation) = AsyncStream<DeviceOrientation?>.makeStream()
        Task {
            continuation.yield(await knownDeviceOrientation())
            continuation.finish()
        }
        Task {
            try? await Task.sleep(for: limit)
            continuation.finish()
        }
        for await orientation in first {
            return orientation
        }
        return nil
    }

    /// Captures a screen and records it with the interface orientation.
    private func capture(_ display: SimulatorDisplay?, to path: String, maxDimension: Int,
                         orientation: DeviceOrientation) async throws -> (shot: Screenshot, record: ScreenshotRecord) {
        let frame = device.screenFrame(screenID: display?.index ?? Self.mainScreenID)
        let interfaceOrientation = if let frame { frame.interfaceOrientation } else { await interfaceOrientation(of: display) }
        let shot = try await Screenshots.capture(udid: udid, display: display?.index, frame: frame, to: path,
                                                 maxDimension: maxDimension, tools: tools)
        let record = ScreenshotRecord(shot, orientation: orientation, interfaceOrientation: interfaceOrientation)
        store.save(record, for: DigitizerTarget(display: display))
        return (shot, record)
    }

    /// Records a screen's size for fractions, from its frame when there is one and with a full screenshot otherwise.
    private func calibrate(_ display: SimulatorDisplay?, orientation: DeviceOrientation) async throws -> ScreenshotRecord {
        guard let frame = device.screenFrame(screenID: display?.index ?? Self.mainScreenID) else {
            return try await capture(display, to: StatePaths.calibration(for: udid).path, maxDimension: Self.fullResolution,
                                     orientation: orientation).record
        }
        let size = Screenshots.size(of: frame)
        let record = ScreenshotRecord(full: size, image: size, orientation: orientation, interfaceOrientation: frame.interfaceOrientation)
        store.save(record, for: DigitizerTarget(display: display))
        return record
    }

    /// The interface orientation `simctl` rotates a screen's screenshots by; nil when CoreSimulator reports none.
    private func interfaceOrientation(of display: SimulatorDisplay?) async -> InterfaceOrientation? {
        try? await device.interfaceOrientations()[display?.index ?? Self.mainScreenID]
    }

    /// The displays of a multi-display device, or none for a single display.
    private func displays() async throws -> [SimulatorDisplay] {
        if let displays = store.displays { return displays }
        // A multi-display device refuses a screenshot without --display and lists its displays instead.
        let path = StatePaths.calibration(for: udid).path
        let result = try await tools.simctlResult(Screenshots.simctlArguments(udid: udid, display: nil, path: path))
        guard result.succeeded else {
            let found = SimulatorDisplay.parse(listing: result.standardOutput + "\n" + result.standardError)
            guard !found.isEmpty else { throw SimDriveError(.screenshot, "simctl could not capture the screen: \(result.diagnostics)") }
            store.displays = found
            return found
        }
        store.displays = []
        // The probe doubles as the first calibration; an existing record may be the one pixel coordinates refer to.
        if store.record(for: .mainScreen) == nil {
            let size = try Screenshots.size(of: path)
            store.save(ScreenshotRecord(full: size, image: size, orientation: await knownDeviceOrientation() ?? .portrait,
                                        interfaceOrientation: await interfaceOrientation(of: nil)),
                       for: .mainScreen)
        }
        return []
    }

    private func display(for selector: DisplaySelector) async throws -> SimulatorDisplay? {
        let displays = try await displays()
        guard !displays.isEmpty else {
            guard selector == .automatic else { throw SimDriveError(.singleDisplay, "\(device.name) has one display.") }
            return nil
        }
        switch selector {
        case .index(let index):
            guard let display = displays.first(where: { $0.index == index }) else {
                throw SimDriveError(.unknownDisplay, "\(device.name) has no display \(index).")
            }
            return display
        case .cover:
            return try display(role: SimulatorDisplay.coverRole, in: displays)
        case .inner:
            return try display(role: SimulatorDisplay.innerRole, in: displays)
        case .automatic:
            let role = try await isClosed() ? SimulatorDisplay.coverRole : SimulatorDisplay.innerRole
            return displays.first { $0.role == role } ?? displays[0]
        }
    }

    private func display(role: String, in displays: [SimulatorDisplay]) throws -> SimulatorDisplay {
        guard let display = displays.first(where: { $0.role == role }) else {
            throw SimDriveError(.unknownDisplay, "\(device.name) has no \(role) display.")
        }
        return display
    }

    /// Whether a foldable is closed. A multi-display device without a hinge counts as closed, showing its primary display.
    private func isClosed() async throws -> Bool {
        guard let hinge = try await hinge.value() else { return true }
        try await hinge.waitForReading()
        return hinge.posture == .closed
    }
}
