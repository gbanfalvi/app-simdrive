import CoreGraphics
import Foundation
import SimDriveNative

/// Where points land: the device's displays, each screen's last screenshot, and how its points map to the digitizer.
@MainActor
final class Screens {
    /// A calibration screenshot keeps its full resolution.
    private static let fullResolution = 0

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
        let orientation = try await deviceOrientation() ?? .portrait
        var record = store.record(for: DigitizerTarget(display: display))
        if let existing = record, existing.orientation != orientation {
            guard !usesPixels else {
                throw SimDriveError(.staleScreenshot, "The device rotated since the last screenshot; take a new one.")
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
            current = try await capture(display, to: StatePaths.calibration(for: udid).path, maxDimension: Self.fullResolution,
                                        orientation: orientation).record
        }
        // Single touchscreens are portrait natively, and TVs landscape.
        let mapping = ScreenMapping(screenshot: current, panelIsLandscape: display?.nativeSize.isLandscape ?? !device.hasTouchscreen,
                                    deviceOrientation: orientation)
        return Screen(display: display, record: current, mapping: mapping)
    }

    func screenshot(to path: String, display selector: DisplaySelector, maxDimension: Int) async throws -> JSONValue {
        let display = try await display(for: selector)
        let orientation = try await deviceOrientation()
        let (shot, _) = try await capture(display, to: path, maxDimension: maxDimension, orientation: orientation ?? .portrait)
        return shot.json(display: display, orientation: orientation)
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

    /// Captures a screen and records it with the interface orientation, which `simctl` reads in parallel.
    private func capture(_ display: SimulatorDisplay?, to path: String, maxDimension: Int,
                         orientation: DeviceOrientation) async throws -> (shot: Screenshot, record: ScreenshotRecord) {
        async let interfaceOrientation = Screenshots.interfaceOrientation(udid: udid, display: display?.index, tools: tools)
        let shot = try await Screenshots.capture(udid: udid, display: display?.index, to: path, maxDimension: maxDimension, tools: tools)
        let record = ScreenshotRecord(shot, orientation: orientation, interfaceOrientation: await interfaceOrientation)
        store.save(record, for: DigitizerTarget(display: display))
        return (shot, record)
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
            store.save(ScreenshotRecord(full: size, image: size, orientation: try await deviceOrientation() ?? .portrait,
                                        interfaceOrientation: await Screenshots.interfaceOrientation(udid: udid, display: nil, tools: tools)),
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
