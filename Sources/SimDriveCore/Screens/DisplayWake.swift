import CoreGraphics
import Foundation
import SimDriveNative

/// Lights a touchscreen whose display dimmed or slept before input reaches it, since the guest drops touches and
/// rotations there and screenshots freeze on the dimmed frame (I6). The device's lock state is kept: a device that was
/// unlocked, as when the display dims while idle, is unlocked again; one that was locked shows its lock screen.
@MainActor
final class DisplayWake {
    /// SpringBoard's lock state, 1 while the device is locked.
    static let lockStateNotification = "com.apple.springboard.lockstate"
    /// A press while dimmed locks the device and keeps it dimmed; the next one lights it, so two presses suffice.
    private static let maximumPresses = 3
    /// The backlight reads on about 1 s after a press (iPhone 17, iOS 27.2).
    private static let lightLimit: Duration = .milliseconds(1500)
    /// The lock state reads unlocked more than 0.5 s after the swipe.
    private static let unlockLimit: Duration = .seconds(3)
    private static let pollInterval: Duration = .milliseconds(100)
    private static let unlockPath = [CGPoint(x: 0.5, y: 0.999), CGPoint(x: 0.5, y: 0.3)]

    private let device: SimulatorDevice?
    private let inputs: DeviceInputs

    /// Nil `device` for a physical device, whose backlight and lock state simdrive cannot read yet; its input is sent as is.
    init(device: SimulatorDevice?, inputs: DeviceInputs) {
        self.device = device
        self.inputs = inputs
    }

    /// Whether a display with this backlight drops input; a screen that reports none, or an unknown state, is left be.
    nonisolated static func needsWake(_ backlight: Backlight?) -> Bool {
        backlight == .dimmed || backlight == .off
    }

    /// Wakes `screen`'s display when it is dimmed or off, and returns whether it did.
    func wake(_ screen: Screen) async throws -> Bool {
        guard let device else { return false }
        let screenID = screen.display?.index ?? Screens.mainScreenID
        guard Self.needsWake(try await device.backlights()[screenID]) else { return false }
        let wasLocked = try isLocked(device)
        var presses = 0
        repeat {
            guard presses < Self.maximumPresses else {
                throw SimDriveError(.displayAsleep, "\(device.name)'s display stayed dimmed after \(presses) Lock presses; "
                                    + "take a screenshot, and wake it with `button lock`.")
            }
            try await inputs.press(.lock, count: 1, hold: CommandParser.defaultButtonHold, legacy: false)
            presses += 1
        } while try await !isLit(screenID, on: device)
        if !wasLocked, try isLocked(device) { try await unlock(screen, on: device) }
        return true
    }

    private func isLit(_ screenID: Int, on device: SimulatorDevice) async throws -> Bool {
        try await poll(every: Self.pollInterval, within: Self.lightLimit) { [device] in
            try await device.backlights()[screenID] == .on ? true : nil
        } ?? false
    }

    /// Swipes up from the bottom edge, and presses Home where the guest ignores the edge, as iOS 17.0 does (F16).
    private func unlock(_ screen: Screen, on device: SimulatorDevice) async throws {
        try await inputs.drag(through: Self.unlockPath.map { screen.digitizerPoint(.normalized($0)) },
                              duration: CommandParser.defaultSwipeDuration, edge: screen.mapping.digitizerEdge(.bottom),
                              on: screen.digitizerTarget)
        if try await waitUntilUnlocked(device) { return }
        try await inputs.press(.home, count: 1, hold: CommandParser.defaultButtonHold, legacy: false)
        guard try await waitUntilUnlocked(device) else {
            throw SimDriveError(.displayAsleep, "\(device.name) lit its display but stayed locked; swipe up from the bottom edge "
                                + "to unlock it.")
        }
    }

    private func waitUntilUnlocked(_ device: SimulatorDevice) async throws -> Bool {
        try await poll(every: Self.pollInterval, within: Self.unlockLimit) { [self] in try isLocked(device) ? nil : true } ?? false
    }

    private func isLocked(_ device: SimulatorDevice) throws -> Bool {
        try device.darwinNotificationState(Self.lockStateNotification) != 0
    }
}
