/// Hardware and Apple TV Remote buttons, named as the command line spells them.
package enum HardwareButton: String, CaseIterable, Sendable {
    case home, lock, volumeUp = "volume-up", volumeDown = "volume-down", siri
    case menu, select, playPause = "play-pause", up, down, left, right, channelUp = "channel-up", channelDown = "channel-down"

    static let usagePage: UInt16 = 0x0C

    /// Consumer-page usages as the guest maps them, not as HID names them: Menu (0x40) is home, the TV button on tvOS;
    /// AC Home (0x223) is the remote's Menu (Back); Power (0x30) locks, or on tvOS opens Control Center.
    var usage: UInt16 {
        switch self {
        case .home: 0x40
        case .lock: 0x30
        case .volumeUp: 0xE9
        case .volumeDown: 0xEA
        case .siri: 0xCF
        case .menu: 0x223
        case .select: 0x41
        case .playPause: 0xCD
        case .up: 0x42
        case .down: 0x43
        case .left: 0x44
        case .right: 0x45
        case .channelUp: 0x9C
        case .channelDown: 0x9D
        }
    }
}

/// A button's state, by CoreDevice `HIDButtonState` case.
enum ButtonState: String { case down, up }

/// The guest's hardware buttons, which on an Apple TV are its remote's.
@MainActor
package final class GuestButtons {
    private static let feature = "com.apple.coredevice.feature.remote.hid.button"
    private let connection: GuestConnection
    private let codec: GuestMessageCodec

    private init(connection: GuestConnection, codec: GuestMessageCodec) {
        self.connection = connection
        self.codec = codec
    }

    package static func open(guest: SimulatorGuest) async throws -> GuestButtons {
        GuestButtons(connection: try await guest.connection(to: feature), codec: guest.codec)
    }

    package var hasFailed: Bool { connection.hasFailed }

    package func press(_ button: HardwareButton, hold: Duration) async throws {
        try connection.post(.buttonEvent, codec.buttonEvent(button, state: .down))
        await pause(hold)
        try connection.post(.buttonEvent, codec.buttonEvent(button, state: .up))
        try await connection.flush()
    }

    package func close() async { await connection.drain() }
}
