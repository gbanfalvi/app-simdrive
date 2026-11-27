import CoreGraphics
import Foundation
import SimDriveNative

/// A device's backlight and lock state, as `DisplayWake` reads them.
@MainActor
protocol PowerSource: AnyObject {
    var name: String { get }
    /// A screen's backlight; nil when the screen reports none.
    func backlight(screenID: Int) async throws -> Backlight?
    /// Whether the device is locked; nil when it cannot tell, as a physical device without a passcode.
    func isLocked() async throws -> Bool?
}

/// A simulator's backlight from CoreSimulator's screens, and its lock state from SpringBoard's notification.
extension SimulatorDevice: PowerSource {
    func backlight(screenID: Int) async throws -> Backlight? { try await backlights()[screenID] }
    func isLocked() async throws -> Bool? { try darwinNotificationState(DisplayWake.lockStateNotification) != 0 }
}

/// A physical device's backlight and lock state from CoreDevice; it has one screen. CoreDevice says only whether a
/// passcode is needed now, which reads true while a device with a passcode is locked and false once unlocked; a device
/// without one reads false either way, so its lock state is unknown.
@MainActor
final class DevicePower: PowerSource {
    let name: String
    private let displays: LazyCapability<CoreDeviceDisplays>

    init(name: String, displays: LazyCapability<CoreDeviceDisplays>) {
        self.name = name
        self.displays = displays
    }

    func backlight(screenID: Int) async throws -> Backlight? { try await displays.value()?.backlight() }

    func isLocked() async throws -> Bool? {
        try await displays.value()?.isPasscodeRequired() == true ? true : nil
    }
}

/// Lights a touchscreen whose display dimmed or slept before input reaches it, since the guest drops touches and
/// rotations there and screenshots freeze on the dimmed frame (I6). The device's lock state is kept: a device that was
/// unlocked, as when the display dims while idle, is unlocked again; one that was locked shows its lock screen, as a
/// physical device with a passcode, which simdrive never types, does. A physical device without one, whose lock state is
/// unknown, is unlocked: pressing Lock on a dimmed display locks it on the way, so it is on its lock screen either way.
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
    /// A physical device's lock screen, which reports no lock state, finishes going away within this after the swipe.
    private static let deviceUnlockSettle: Duration = .milliseconds(800)
    private static let pollInterval: Duration = .milliseconds(100)
    private static let unlockPath = [CGPoint(x: 0.5, y: 0.999), CGPoint(x: 0.5, y: 0.3)]

    private let power: (any PowerSource)?
    private let inputs: DeviceInputs

    /// Nil `power` for a device whose backlight cannot be read; its input is sent as is.
    init(power: (any PowerSource)?, inputs: DeviceInputs) {
        self.power = power
        self.inputs = inputs
    }

    /// Whether a display with this backlight drops input; a screen that reports none, or an unknown state, is left be.
    nonisolated static func needsWake(_ backlight: Backlight?) -> Bool {
        backlight == .dimmed || backlight == .off
    }

    /// Wakes `screen`'s display when it is dimmed or off, and returns whether it did.
    func wake(_ screen: Screen) async throws -> Bool {
        guard let power else { return false }
        let screenID = screen.display?.index ?? Screens.mainScreenID
        guard Self.needsWake(try await power.backlight(screenID: screenID)) else { return false }
        let wasLocked = try await power.isLocked()
        var presses = 0
        repeat {
            guard presses < Self.maximumPresses else {
                throw SimDriveError(.displayAsleep, "\(power.name)'s display stayed dimmed after \(presses) Lock presses; "
                                    + "take a screenshot, and wake it with `button lock`.")
            }
            try await inputs.press(.lock, count: 1, hold: CommandParser.defaultButtonHold, legacy: false)
            presses += 1
        } while try await !isLit(screenID, on: power)
        if wasLocked != true, try await power.isLocked() ?? true { try await unlock(screen, on: power) }
        return true
    }

    private func isLit(_ screenID: Int, on power: any PowerSource) async throws -> Bool {
        try await poll(every: Self.pollInterval, within: Self.lightLimit) { [power] in
            try await power.backlight(screenID: screenID) == .on ? true : nil
        } ?? false
    }

    /// Swipes up from the bottom edge, and presses Home where the guest ignores the edge, as iOS 17.0 does (F16). A
    /// physical device reports no lock state, so its unlock is taken on trust after a moment.
    private func unlock(_ screen: Screen, on power: any PowerSource) async throws {
        try await inputs.drag(through: Self.unlockPath.map { screen.digitizerPoint(.normalized($0)) },
                              duration: CommandParser.defaultSwipeDuration, edge: screen.mapping.digitizerEdge(.bottom),
                              on: screen.digitizerTarget)
        guard try await power.isLocked() != nil else {
            await pause(Self.deviceUnlockSettle)
            return
        }
        if try await waitUntilUnlocked(power) { return }
        try await inputs.press(.home, count: 1, hold: CommandParser.defaultButtonHold, legacy: false)
        guard try await waitUntilUnlocked(power) else {
            throw SimDriveError(.displayAsleep, "\(power.name) lit its display but stayed locked; swipe up from the bottom edge "
                                + "to unlock it.")
        }
    }

    private func waitUntilUnlocked(_ power: any PowerSource) async throws -> Bool {
        try await poll(every: Self.pollInterval, within: Self.unlockLimit) { [power] in try await power.isLocked() == false ? true : nil } ?? false
    }
}
