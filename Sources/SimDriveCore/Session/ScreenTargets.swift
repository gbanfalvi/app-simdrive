import CoreGraphics
import Foundation
import SimDriveNative

/// Where points land: the device's displays, each screen's last screenshot, and how its points map to the digitizer.
@MainActor
final class ScreenTargets {
    /// A screen to touch, with the screenshot its points refer to.
    struct Target {
        let display: SimulatorDisplay?
        let record: ScreenRecord
        let mapping: ScreenMapping

        var digitizerTarget: DigitizerTarget { display?.digitizerTarget ?? .mainScreen }

        /// The point as fractions of the screenshot, clamped to the screen.
        func normalizedPoint(_ point: ScreenPoint) -> CGPoint {
            let normalized = switch point {
            case .normalized(let value): value
            case .pixels(let value):
                CGPoint(x: value.x / CGFloat(record.image.width), y: value.y / CGFloat(record.image.height))
            }
            return CGPoint(x: min(max(normalized.x, 0), 1), y: min(max(normalized.y, 0), 1))
        }

        func digitizerPoint(_ point: ScreenPoint) -> CGPoint { mapping.digitizerPoint(normalizedPoint(point)) }

        func json(_ point: ScreenPoint) -> JSONValue {
            let normalized = normalizedPoint(point)
            return ["x": .number(normalized.x), "y": .number(normalized.y)]
        }
    }

    private let udid: String
    private let device: SimulatorDevice
    private let tools: DeveloperTools
    private let orientation: LazyCapability<GuestOrientation>
    private let hinge: LazyCapability<Hinge>
    private let store: ScreenStore
    private var displays: [SimulatorDisplay]?

    init(udid: String, device: SimulatorDevice, tools: DeveloperTools, orientation: LazyCapability<GuestOrientation>,
         hinge: LazyCapability<Hinge>) {
        self.udid = udid
        self.device = device
        self.tools = tools
        self.orientation = orientation
        self.hinge = hinge
        store = ScreenStore(url: StatePaths.screens(for: udid))
    }

    /// The display a point refers to, with the rotation of its last screenshot. Fractions take a calibration
    /// screenshot when there is none for the current orientation; pixels need the caller's own.
    func target(_ selector: DisplaySelector, usesPixels: Bool) async throws -> Target {
        guard device.hasTouchscreen else {
            throw SimDriveError(.noTouchscreen, "\(device.name) has no touchscreen; use button or key to move focus.")
        }
        let display = try await resolveDisplay(selector)
        let orientation = try await currentOrientation()
        var record = store.record(for: display?.digitizerTarget ?? .mainScreen)
        if let existing = record, existing.orientation != orientation {
            guard !usesPixels else {
                throw SimDriveError(.staleScreenshot, "The device rotated since the last screenshot; take a new one.")
            }
            record = nil
        }
        let current: ScreenRecord
        if let record {
            current = record
        } else {
            guard !usesPixels else {
                throw SimDriveError(.noScreenshot, "Pixel coordinates refer to the last screenshot; take one, or pass fractions such as 0.5 0.5.")
            }
            current = try await calibrate(display: display, orientation: orientation)
        }
        let mapping = ScreenMapping(screenshot: current, panelIsLandscape: display?.nativeSize.isLandscape ?? false,
                                    deviceOrientation: orientation)
        return Target(display: display, record: current, mapping: mapping)
    }

    func screenshot(to path: String, display selector: DisplaySelector, maxDimension: Int) async throws -> JSONValue {
        let display = try await resolveDisplay(selector)
        let orientation = try await currentOrientation()
        let canRotate = try await self.orientation.value() != nil
        async let interfaceOrientation = Screenshots.interfaceOrientation(udid: udid, display: display?.index, tools: tools)
        let shot = try await Screenshots.capture(udid: udid, display: display?.index, to: path, maxDimension: maxDimension, tools: tools)
        store.save(ScreenRecord(shot, orientation: orientation, interfaceOrientation: await interfaceOrientation),
                   for: display?.digitizerTarget ?? .mainScreen)
        return ["path": .string(shot.path), "width": .number(Double(shot.image.width)), "height": .number(Double(shot.image.height)),
                "fullPath": .string(shot.fullPath), "fullWidth": .number(Double(shot.full.width)),
                "fullHeight": .number(Double(shot.full.height)), "display": JSONValue(display?.index),
                "orientation": canRotate ? .string(orientation.name) : .null]
    }

    /// Forgets every screenshot, since a new foreground app may rotate the interface without rotating the device.
    func forgetScreenshots() {
        store.removeAll()
    }

    func displaysJSON() async throws -> JSONValue {
        .array(try await knownDisplays().map(\.json))
    }

    /// A device that cannot rotate, such as an Apple TV, counts as portrait.
    func currentOrientation() async throws -> DeviceOrientation {
        guard let control = try await orientation.value() else { return .portrait }
        return try await control.read().orientation ?? .portrait
    }

    private func calibrate(display: SimulatorDisplay?, orientation: DeviceOrientation) async throws -> ScreenRecord {
        async let interfaceOrientation = Screenshots.interfaceOrientation(udid: udid, display: display?.index, tools: tools)
        let shot = try await Screenshots.capture(udid: udid, display: display?.index,
            to: StatePaths.calibration(for: udid).path, maxDimension: 0, tools: tools)
        let record = ScreenRecord(shot, orientation: orientation, interfaceOrientation: await interfaceOrientation)
        store.save(record, for: display?.digitizerTarget ?? .mainScreen)
        return record
    }

    private func knownDisplays() async throws -> [SimulatorDisplay] {
        if let displays { return displays }
        // A multi-display device refuses a screenshot without --display and lists its displays instead.
        let path = StatePaths.calibration(for: udid).path
        let result = try await tools.simctlResult(Screenshots.simctlArguments(udid: udid, display: nil, path: path))
        guard result.succeeded else {
            let found = SimulatorDisplay.parse(listing: result.standardOutput + "\n" + result.standardError)
            guard !found.isEmpty else { throw SimDriveError(.screenshot, "simctl could not capture the screen: \(result.diagnostics)") }
            displays = found
            return found
        }
        displays = []
        // The probe doubles as the first calibration; an existing record may be the one pixel coordinates refer to.
        if store.record(for: .mainScreen) == nil {
            let size = try Screenshots.size(of: path)
            store.save(ScreenRecord(full: size, image: size, orientation: try await currentOrientation(),
                                    interfaceOrientation: await Screenshots.interfaceOrientation(udid: udid, display: nil, tools: tools)),
                       for: .mainScreen)
        }
        return []
    }

    private func resolveDisplay(_ selector: DisplaySelector) async throws -> SimulatorDisplay? {
        let displays = try await knownDisplays()
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
