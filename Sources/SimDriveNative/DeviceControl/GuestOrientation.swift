import ABIBridge

/// A device orientation, by CoreDevice `DeviceOrientation` raw value.
package enum DeviceOrientation: String, Codable, CaseIterable, Sendable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight
}

/// How the device itself lies: upright in an orientation, or flat. `other` keeps a CoreDevice raw value this list lacks.
package enum PhysicalOrientation: Equatable, Sendable {
    case upright(DeviceOrientation)
    case faceUp, faceDown, unknown
    case other(String)

    /// From CoreDevice's `DeviceOrientation` raw value.
    init(rawValue: String) {
        if let orientation = DeviceOrientation(rawValue: rawValue) {
            self = .upright(orientation)
            return
        }
        switch rawValue {
        case "faceUp": self = .faceUp
        case "faceDown": self = .faceDown
        case "unknown": self = .unknown
        default: self = .other(rawValue)
        }
    }
}

/// The guest's orientation readings.
package struct GuestOrientationReading: Equatable, Sendable {
    /// The last orientation that was not flat, which the interface follows; nil when the guest reports none.
    package let orientation: DeviceOrientation?
    /// The device itself, which may lie flat.
    package let physical: PhysicalOrientation
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
    package static func open(guest: Guest) async throws -> GuestOrientation? {
        guard guest.hasService(feature) else { return nil }
        return GuestOrientation(connection: try await guest.connection(to: feature), codec: guest.codec)
    }

    package var hasFailed: Bool { connection.hasFailed }

    package func read() async throws -> GuestOrientationReading {
        try await send(codec.currentOrientationRequest())
    }

    package func set(_ orientation: DeviceOrientation) async throws -> GuestOrientationReading {
        try await send(codec.orientationRequest(orientation.rawValue))
    }

    /// Sets the device back to how it lay, flat included. On a physical device a set orientation holds until set again,
    /// since CoreDevice has no call to hand it back to the device's sensor. An unknown orientation is left as it is.
    package func restore(_ physical: PhysicalOrientation) async throws {
        let name: String? = switch physical {
        case .upright(let orientation): orientation.rawValue
        case .faceUp: "faceUp"
        case .faceDown: "faceDown"
        case .unknown, .other: nil
        }
        guard let name else { return }
        _ = try await send(codec.orientationRequest(name))
    }

    private func send(_ request: NativeSwiftValue) async throws -> GuestOrientationReading {
        try codec.orientation(from: await connection.request(.orientation, request))
    }
}
