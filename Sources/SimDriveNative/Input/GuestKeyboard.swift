import AppKit

/// The guest's main hardware keyboard. While it exists, the guest counts a hardware keyboard as connected.
@MainActor
package final class GuestKeyboard {
    private static let keyHold: Duration = .milliseconds(40)

    private let connection: GuestConnection
    private let translator: KeyReportTranslator
    private let service: GuestHIDService

    private init(connection: GuestConnection, translator: KeyReportTranslator, service: GuestHIDService) {
        self.connection = connection
        self.translator = translator
        self.service = service
    }

    /// Creates the guest's keyboard and waits until the guest takes its keys.
    package static func open(guest: SimulatorGuest, bindings: KeyboardBindings) async throws -> GuestKeyboard {
        let connection = try await guest.connection(to: GuestHIDService.universalHIDFeature)
        let service = try await connection.createService(try bindings.mainKeyboardDescriptor())
        let keyboard = GuestKeyboard(connection: connection, translator: try bindings.makeTranslator(), service: service)
        await pause(GuestInputTiming.settle)
        return keyboard
    }

    package var hasFailed: Bool { connection.hasFailed }

    /// Presses and releases a key, with the modifiers of `flags` held around it.
    package func press(keyCode: UInt16, flags: NSEvent.ModifierFlags) async throws {
        if !flags.isEmpty { try send(.flagsChanged, keyCode: 0, flags: flags) }
        try send(.keyDown, keyCode: keyCode, flags: flags)
        await pause(Self.keyHold)
        try send(.keyUp, keyCode: keyCode, flags: flags)
        if !flags.isEmpty { try send(.flagsChanged, keyCode: 0, flags: []) }
    }

    /// Removes the guest's keyboard, which releases what it held.
    package func close() async throws {
        try await service.remove()
        try await connection.flush()
    }

    private func send(_ type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) throws {
        // The observer reads the key from its key code alone, not from characters.
        guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode) else {
            throw SimDriveError(.keyboardEvent, "AppKit could not create a key event.")
        }
        for report in try translator.reports(for: event) { try service.send(report) }
    }
}
