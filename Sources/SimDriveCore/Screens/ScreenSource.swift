import CoreGraphics
import Foundation
import SimDriveNative

/// What `Screens` reads from a device's screens, which a simulator's CoreSimulator and a physical device's capture
/// service provide differently. Screen IDs are CoreSimulator's: 1 for a single display.
@MainActor
protocol ScreenSource: AnyObject {
    var name: String { get }
    var hasTouchscreen: Bool { get }
    /// Pixels per point; nil when unknown.
    var scale: Double? { get }
    /// The displays of a multi-display device, or none for a single display. A single display's probe may capture its
    /// screen to `probePath` on the way, returning its size.
    func displays(probePath: String) async throws -> (displays: [SimulatorDisplay], probed: PixelSize?)
    /// The screen's framebuffer, in its native orientation, when the screen's pixels can be read without a capture.
    func frame(screenID: Int) -> ScreenFrame?
    /// The pixels of a square around a unit point of the native screen, for watching them settle; nil when unreadable.
    func pixels(screenID: Int, around unitPoint: CGPoint, side: Int) -> [UInt8]?
    /// The interface orientation the screen shows; nil when the device does not report one.
    func interfaceOrientation(screenID: Int) async -> InterfaceOrientation?
    /// Captures a screen upright to `path`, downscaled to `maxDimension` with the original kept, as `Screenshots` does.
    func capture(_ display: SimulatorDisplay?, frame: ScreenFrame?, to path: String, maxDimension: Int) async throws -> Screenshot
}

/// A simulator's screens: CoreSimulator's framebuffers, with `simctl` for displays and screens that have none.
@MainActor
final class SimulatorScreens: ScreenSource {
    private let udid: String
    private let device: SimulatorDevice
    private let tools: DeveloperTools

    init(udid: String, device: SimulatorDevice, tools: DeveloperTools) {
        self.udid = udid
        self.device = device
        self.tools = tools
    }

    var name: String { device.name }
    var hasTouchscreen: Bool { device.hasTouchscreen }
    var scale: Double? { device.screenScale }

    func displays(probePath: String) async throws -> (displays: [SimulatorDisplay], probed: PixelSize?) {
        // A multi-display device refuses a screenshot without --display and lists its displays instead.
        let result = try await tools.simctlResult(Screenshots.simctlArguments(udid: udid, display: nil, path: probePath))
        guard result.succeeded else {
            let found = SimulatorDisplay.parse(listing: result.standardOutput + "\n" + result.standardError)
            guard !found.isEmpty else { throw SimDriveError(.screenshot, "simctl could not capture the screen: \(result.diagnostics)") }
            return (found, nil)
        }
        return ([], try Screenshots.size(of: probePath))
    }

    func frame(screenID: Int) -> ScreenFrame? { device.screenFrame(screenID: screenID) }

    func pixels(screenID: Int, around unitPoint: CGPoint, side: Int) -> [UInt8]? {
        device.screenPixels(screenID: screenID, around: unitPoint, side: side)
    }

    func interfaceOrientation(screenID: Int) async -> InterfaceOrientation? {
        try? await device.interfaceOrientations()[screenID]
    }

    func capture(_ display: SimulatorDisplay?, frame: ScreenFrame?, to path: String, maxDimension: Int) async throws -> Screenshot {
        try await Screenshots.capture(udid: udid, display: display?.index, frame: frame, to: path, maxDimension: maxDimension, tools: tools)
    }
}

/// A physical device's main screen, through its capture service. Its pixels cannot be read without a capture, so
/// element taps do not wait for them to settle, and its interface orientation is taken from the device's.
@MainActor
final class DeviceScreens: ScreenSource {
    let name: String
    let hasTouchscreen: Bool
    private let capture: LazyCapability<GuestScreenCapture>

    init(name: String, hasTouchscreen: Bool, capture: LazyCapability<GuestScreenCapture>) {
        self.name = name
        self.hasTouchscreen = hasTouchscreen
        self.capture = capture
    }

    /// Fractions need no scale on a device: calibration captures the screen.
    var scale: Double? { nil }

    func displays(probePath: String) async throws -> (displays: [SimulatorDisplay], probed: PixelSize?) { ([], nil) }
    func frame(screenID: Int) -> ScreenFrame? { nil }
    func pixels(screenID: Int, around unitPoint: CGPoint, side: Int) -> [UInt8]? { nil }
    func interfaceOrientation(screenID: Int) async -> InterfaceOrientation? { nil }

    func capture(_ display: SimulatorDisplay?, frame: ScreenFrame?, to path: String, maxDimension: Int) async throws -> Screenshot {
        let capture = try await capture.required(orThrow: SimDriveError(.screenshot, "\(name) has no screen capture service."))
        return try Screenshots.write(try await capture.image(), to: path, maxDimension: maxDimension)
    }
}
