import ABIBridge
import Foundation

/// A paired physical device as CoreDevice lists it, connected or not.
package struct PhysicalDeviceRecord: Equatable, Sendable {
    private static let appleTVProductPrefix = "AppleTV"

    /// CoreDevice's identifier, which names the device to simdrive and in setting actions.
    package let identifier: UUID
    package let name: String
    /// The hardware UDID, such as `00008130-001A35A60EE8001C`.
    package let udid: String?
    /// Such as `iPhone16,1` or `AppleTV14,1`.
    package let productType: String?
    package let osVersion: String?
    package let isConnected: Bool

    package init(identifier: UUID, name: String, udid: String?, productType: String?, osVersion: String?, isConnected: Bool) {
        self.identifier = identifier
        self.name = name
        self.udid = udid
        self.productType = productType
        self.osVersion = osVersion
        self.isConnected = isConnected
    }

    package var isAppleTV: Bool { productType?.hasPrefix(Self.appleTVProductPrefix) ?? false }
    package var platform: String { isAppleTV ? "tvOS" : "iOS" }
    package var majorOSVersion: Int? { osVersion.flatMap { $0.split(separator: ".").first.flatMap { Int($0) } } }

    /// Whether `name` names this device, by CoreDevice identifier or hardware UDID, ignoring case.
    package func isNamed(_ name: String) -> Bool {
        identifier.uuidString.caseInsensitiveCompare(name) == .orderedSame
            || udid.map { $0.caseInsensitiveCompare(name) == .orderedSame } ?? false
    }
}

/// The physical devices paired with this Mac.
@MainActor
package enum PhysicalDevices {
    private static let simulatorsVisibility = "simulators"
    private static let connectedState = "connected"

    /// The paired physical devices CoreDevice lists, leaving out simulators.
    package static func paired() async throws -> [PhysicalDeviceRecord] {
        let manager = try await CoreDeviceManager.shared()
        let runtime = ABIRuntime.shared
        let read = try await runtime.prepare { runtime in
            let managerType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
            let devices = try await managerType.resolve(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
            let remote = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
            let deviceInfo = try await remote.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
            let infoType = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
            func string(_ name: String) async throws -> NativeSwiftMethod<() -> String?> {
                try await infoType.resolve(.swift(.getter(name, as: (() -> String?).self)))
            }
            let name = try await string("name"), udid = try await string("udid")
            let productType = try await string("productType"), osVersion = try await string("osVersion")
            let visibility = try await enumName(of: "visibilityClass", type: "CoreDevice.DeviceVisibilityClass", in: infoType, runtime: runtime)
            let state = try await enumName(of: "state", type: "CoreDeviceProtocols.DeviceState", in: infoType, runtime: runtime)
            return { () throws -> [PhysicalDeviceRecord] in
                try unsafe devices.unsafeInvoke(on: manager).compactMap { identifier, device in
                    let info = try unsafe deviceInfo.unsafeInvoke(on: device)
                    guard try visibility(info) != simulatorsVisibility else { return nil }
                    return PhysicalDeviceRecord(identifier: identifier,
                                                name: try unsafe name.unsafeInvoke(on: info) ?? identifier.uuidString,
                                                udid: try unsafe udid.unsafeInvoke(on: info),
                                                productType: try unsafe productType.unsafeInvoke(on: info),
                                                osVersion: try unsafe osVersion.unsafeInvoke(on: info),
                                                isConnected: try state(info) == connectedState)
                }
            }
        }
        return try read().sorted { $0.name < $1.name }
    }

    /// Reads a `String`-backed enum property of `DeviceInfo` as its raw value.
    private static func enumName(of property: String, type name: String, in infoType: NativeSwiftType,
                                 runtime: ABIRuntime) async throws -> (NativeSwiftValue) throws -> String {
        let type = try await runtime.resolve(.swift(.type(name)))
        let abis = try NativeType.opaqueABIs(for: [type])
        let getter = try await infoType.resolve(.swift(.getter(property, as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let rawValue = try await type.resolve(.swift(.getter("rawValue", as: (() -> String).self, valueABIs: abis,
                                                             receiverABI: abis[type])))
        return { info in try unsafe rawValue.unsafeInvoke(on: getter.unsafeInvoke(on: info)) }
    }
}
