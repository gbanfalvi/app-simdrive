import ABIBridge

/// A device orientation, by CoreDevice `DeviceOrientation` raw value.
package enum DeviceOrientation: String, Codable, CaseIterable, Sendable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight
}

/// The guest's orientation readings.
package struct GuestOrientationReading: Equatable, Sendable {
    /// The last orientation that was not flat, which the interface follows; nil when the guest reports none.
    package let orientation: DeviceOrientation?
    /// The CoreDevice `DeviceOrientation` raw value of the device itself, which may be `faceUp`, `faceDown` or `unknown`.
    package let physical: String
}

/// Reads and sets the guest's device orientation.
@MainActor
package final class GuestOrientation {
    private static let feature = "com.apple.coredevice.feature.remote.devicecontrol.orientation"
    private let connection: GuestConnection
    private let codec: GuestMessageCodec

    private init(connection: GuestConnection, codec: GuestMessageCodec) {
        self.connection = connection
        self.codec = codec
    }

    /// The guest's orientation service, or nil when it has none, as on tvOS.
    package static func open(guest: SimulatorGuest) async throws -> GuestOrientation? {
        guard guest.hasService(feature) else { return nil }
        return GuestOrientation(connection: try await guest.connection(to: feature), codec: guest.codec)
    }

    package var hasFailed: Bool { connection.hasFailed }

    package func read() async throws -> GuestOrientationReading {
        try await send(codec.currentOrientationRequest())
    }

    package func set(_ orientation: DeviceOrientation) async throws -> GuestOrientationReading {
        try await send(codec.orientationRequest(orientation))
    }

    private func send(_ request: NativeSwiftValue) async throws -> GuestOrientationReading {
        try codec.orientation(from: await connection.request(.orientation, request))
    }
}
