import CoreGraphics

/// The guest's Indigo digitizer, which takes touches on any of the device's panels.
@MainActor
package final class GuestTouchscreen {
    private static let feature = "com.apple.coredevice.feature.remote.hid.digitizer"
    private let connection: GuestHIDConnection
    private let codec: GuestHIDCodec

    package init(guest: SimulatorGuestHID) async throws {
        connection = try await guest.connection(to: Self.feature)
        codec = guest.codec
    }

    package var hasFailed: Bool { connection.hasFailed }

    /// `point` is in unit coordinates of the target panel in its native orientation.
    package func send(_ point: CGPoint, phase: TouchPhase, edge: TouchEdge, target: String) throws {
        try connection.post(.digitizerEvent, codec.digitizerEvent(at: point, phase: phase, edge: edge, target: target))
    }

    package func flush() async throws { try await connection.flush() }
}

/// The guest's hardware buttons, as HID usages.
@MainActor
package final class GuestButtons {
    private static let feature = "com.apple.coredevice.feature.remote.hid.button"
    private let connection: GuestHIDConnection
    private let codec: GuestHIDCodec

    package init(guest: SimulatorGuestHID) async throws {
        connection = try await guest.connection(to: Self.feature)
        codec = guest.codec
    }

    package var hasFailed: Bool { connection.hasFailed }

    package func send(usagePage: UInt16, usage: UInt16, state: ButtonState) throws {
        try connection.post(.buttonEvent, codec.buttonEvent(usagePage: usagePage, usage: usage, state: state))
    }

    package func flush() async throws { try await connection.flush() }
}
