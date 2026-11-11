import AppKit

/// The guest's main hardware keyboard. While its service exists, the guest counts a hardware keyboard as connected.
@MainActor
package final class GuestKeyboard {
    private let connection: GuestHIDConnection
    private let bindings: KeyboardBindings
    private let translator: KeyboardReports.Translator
    private var service: HIDService?

    package init(guest: SimulatorGuestHID, bindings: KeyboardBindings) async throws {
        connection = try await guest.connection(to: HIDService.universalHIDFeature)
        self.bindings = bindings
        translator = try bindings.makeTranslator()
    }

    package var hasFailed: Bool { connection.hasFailed }

    /// Creates the guest keyboard service if it does not exist yet, and returns whether it did.
    @discardableResult
    package func attach() async throws -> Bool {
        guard service == nil else { return false }
        service = try await connection.createService(try bindings.mainKeyboardDescriptor())
        return true
    }

    package func setModifiers(_ flags: NSEvent.ModifierFlags) async throws {
        try await send(.flagsChanged, keyCode: 0, flags: flags)
    }

    package func keyDown(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) async throws {
        try await send(.keyDown, keyCode: keyCode, flags: flags)
    }

    package func keyUp(_ keyCode: UInt16, flags: NSEvent.ModifierFlags) async throws {
        try await send(.keyUp, keyCode: keyCode, flags: flags)
    }

    /// Removes the guest service, which releases what it held.
    package func stop() async throws {
        try await service?.stop()
        service = nil
        try await connection.flush()
    }

    private func send(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) async throws {
        // The observer reads the key from its key code alone, not from characters.
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) else {
            throw NativeError("keyboard-event", "AppKit could not create a key event.")
        }
        let reports = try translator.reports(for: event)
        guard !reports.isEmpty else { return }
        try await attach()
        for report in reports { try service?.send(report) }
    }
}
