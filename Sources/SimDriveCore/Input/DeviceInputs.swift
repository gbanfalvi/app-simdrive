import AppKit
import SimDriveNative

/// The guest's keyboard, touchscreen and buttons, each connected on first use and again once its connection ends. All
/// are released after a short idle period: an attached keyboard changes how the guest behaves, and while simdrive holds
/// the digitizer, the guest drops other clients' touches.
@MainActor
final class DeviceInputs {
    private enum Timing {
        /// Presses closer together than this can read as one double or long press.
        static let repeatGap: Duration = .milliseconds(150)
        static let idleRelease: Duration = .seconds(30)
    }

    private let keyboardBindings: LazyCapability<KeyboardBindings>
    private let keyboard: LazyCapability<GuestKeyboard>
    private let touchscreen: LazyCapability<GuestTouchscreen>
    private let buttons: LazyCapability<GuestButtons>
    private let legacyButtons: LazyCapability<LegacyGuestButtons>
    private lazy var idle = IdleRelease(after: Timing.idleRelease) { [weak self] in await self?.release() }

    init(guest: SimulatorGuest) {
        let keyboardBindings = LazyCapability<KeyboardBindings> { try await KeyboardBindings() }
        self.keyboardBindings = keyboardBindings
        keyboard = LazyCapability(isUsable: { !$0.hasFailed }, close: { try? await $0.close() }) {
            try await GuestKeyboard.open(guest: guest, bindings: try await Self.connected(keyboardBindings))
        }
        touchscreen = LazyCapability(isUsable: { !$0.hasFailed }, close: { await $0.close() }) {
            try await GuestTouchscreen.open(guest: guest)
        }
        buttons = LazyCapability(isUsable: { !$0.hasFailed }, close: { await $0.close() }) {
            try await GuestButtons.open(guest: guest)
        }
        legacyButtons = LazyCapability(isUsable: { !$0.hasFailed }, close: { await $0.close() }) {
            try await LegacyGuestButtons.open(guest: guest)
        }
    }

    func press(_ stroke: KeyStroke, modifiers: NSEvent.ModifierFlags, count: Int) async throws {
        try await idle.hold {
            let keyboard = try await Self.connected(keyboard)
            let flags = stroke.needsShift ? modifiers.union(.shift) : modifiers
            for index in 0..<count {
                if index > 0 { await pause(Timing.repeatGap) }
                try await keyboard.press(keyCode: stroke.keyCode, flags: flags)
            }
            try await keyboard.flush()
        }
    }

    func type(_ keys: [KeyboardLayout.Key]) async throws {
        try await idle.hold {
            let keyboard = try await Self.connected(keyboard)
            try keyboard.type(keys)
            try await keyboard.flush()
        }
    }

    func tap(at point: CGPoint, on target: DigitizerTarget) async throws {
        try await idle.hold { try await Self.connected(touchscreen).tap(at: point, target: target) }
    }

    func drag(through path: [CGPoint], duration: Duration, edge: ScreenEdge?, on target: DigitizerTarget) async throws {
        try await idle.hold { try await Self.connected(touchscreen).drag(through: path, duration: duration, edge: edge, target: target) }
    }

    func drag(through first: [CGPoint], and second: [CGPoint], duration: Duration, on target: DigitizerTarget) async throws {
        try await idle.hold { try await Self.connected(touchscreen).drag(through: first, and: second, duration: duration, target: target) }
    }

    /// `legacy` presses through the route Xcode 27.3 removed, which fails there with `legacy-buttons-unavailable`.
    func press(_ button: HardwareButton, count: Int, hold: Duration, legacy: Bool) async throws {
        try await idle.hold {
            let buttons: any ButtonPresser = legacy ? try await Self.connected(legacyButtons) : try await Self.connected(buttons)
            for index in 0..<count {
                if index > 0 { await pause(Timing.repeatGap) }
                try await buttons.press(button, hold: hold)
            }
        }
    }

    /// Prepares the key translation that the keyboard needs, without attaching a keyboard to the guest.
    func prepareKeyboard() async throws {
        _ = try await Self.connected(keyboardBindings)
    }

    /// Closes every input connection, so the guest no longer counts a hardware keyboard and takes other clients' touches.
    /// The next input opens them again.
    func release() async {
        idle.cancel()
        await keyboard.close()
        await touchscreen.close()
        await buttons.close()
        await legacyButtons.close()
    }

    /// Inputs open or throw, so they are never missing.
    private static func connected<Input>(_ input: LazyCapability<Input>) async throws -> Input {
        try await input.required(orThrow: SimDriveError(.guestConnection, "The guest did not open its input service."))
    }
}
