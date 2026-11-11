import ABIBridge
import Foundation

/// CoreDevice's device manager for default devices and simulators, created and initialized once per process.
@MainActor
enum CoreDeviceRuntime {
    private static var manager: NativeSwiftValue?

    static func deviceManager() async throws -> NativeSwiftValue {
        if let manager { return manager }
        try await NativeFrameworks.load(NativeFrameworks.coreDevicePath)
        let created = try await ABIRuntime.shared.prepare { runtime in
            let service = try await runtime.resolve(.swift(.type("CoreDevice.CoreDeviceService")))
            let sharedConnection = try await service.resolve(.swift(.staticGetter("sharedConnection", as: (() -> NativeSwiftValue).self)))
            let connection = try unsafe sharedConnection.unsafeInvoke()
            let visibility = try await runtime.resolve(.swift(.type("CoreDevice.DeviceVisibilityClass")))
            let classes = try ["default", "simulators"].map { try visibility.makeEnumCase(named: $0) }
            let type = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
            let make = try await type.resolve(.swift(.initializer("init(serviceConnection:allowedDeviceVisibilityClasses:)",
                as: ((NativeSwiftValue, [NativeSwiftValue]) -> NativeSwiftValue).self)))
            return try unsafe make.unsafeInvoke(connection, classes)
        }
        let type = try await ABIRuntime.shared.resolve(.swift(.type("CoreDevice.DeviceManager")))
        let initialize = try await type.resolve(.swift(.method("awaitFullInitialization()", as: (() async -> Void).self)))
        try await unsafe initialize.unsafeInvoke(on: created)
        manager = created
        return created
    }

    /// The CoreDevice identifier of the simulator `udid`; simulator UDIDs are not keys of `DeviceManager.devices`.
    static func simulatorIdentifier(udid: String) async throws -> String? {
        let manager = try await deviceManager()
        let runtime = ABIRuntime.shared
        let managerType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
        let devices = try await managerType.resolve(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
        let remote = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
        let deviceInfo = try await remote.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let infoType = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
        let readUDID = try await infoType.resolve(.swift(.getter("udid", as: (() -> String?).self)))
        var match: String?
        for (identifier, object) in try unsafe devices.unsafeInvoke(on: manager) {
            let info = try unsafe deviceInfo.unsafeInvoke(on: object)
            if try unsafe readUDID.unsafeInvoke(on: info)?.caseInsensitiveCompare(udid) == .orderedSame {
                guard match == nil else {
                    throw NativeError("coredevice-identity", "More than one CoreDevice record matches the simulator \(udid).")
                }
                match = identifier.uuidString
            }
        }
        return match
    }
}

/// A CoreDevice `RemoteDevice` and its capabilities.
@MainActor
final class CoreDeviceRemote {
    let runtime: ABIRuntime
    let object: NativeSwiftValue
    let type: NativeSwiftType
    private let supportsFeature: NativeSwiftMethod<(String) -> Bool>

    init(identifier: String) async throws {
        let manager = try await CoreDeviceRuntime.deviceManager()
        let runtime = ABIRuntime.shared
        guard let uuid = UUID(uuidString: identifier) else {
            throw NativeError("coredevice-identifier", "The CoreDevice identifier \(identifier) is not a UUID.")
        }
        let (object, type, supportsFeature) = try await runtime.prepare { runtime in
            let managerType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
            let devices = try await managerType.resolve(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
            guard let object = try unsafe devices.unsafeInvoke(on: manager)[uuid] else {
                throw NativeError("coredevice-device", "CoreDevice no longer lists the device.")
            }
            let type = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
            let supportsFeature = try await type.resolve(.swift(.method("supportsFeature(identifiedBy:)", as: ((String) -> Bool).self)))
            return (object, type, supportsFeature)
        }
        self.runtime = runtime
        self.object = object
        self.type = type
        self.supportsFeature = supportsFeature
    }

    func supports(_ feature: String) throws -> Bool {
        try unsafe supportsFeature.unsafeInvoke(on: object, feature)
    }

    func hardwareModel() async throws -> String? {
        let deviceInfo = try await type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let info = try unsafe deviceInfo.unsafeInvoke(on: object)
        let hardware = try await info.type.resolve(.swift(.getter("hardwareModel", as: (() -> String?).self)))
        return try unsafe hardware.unsafeInvoke(on: info)
    }

    func implementation(capability name: String, feature: String) async throws -> NativeSwiftValue {
        guard try supports(feature) else {
            throw NativeError("coredevice-capability", "The device does not expose \(feature).")
        }
        let capability = try await runtime.resolve(.swift(.type("CoreDevice." + name)))
        let markerType = try await runtime.resolve(.swift(.type("CoreDevice.CapabilityStaticMember", genericArguments: [.type(capability)])))
        let abis: [NativeSwiftType: NativeType] = [markerType: try .opaque(named: markerType.name)]
        let make = try await markerType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let marker = try unsafe make.unsafeInvoke()
        let get = try await type.resolve(.swift(.method("getImplementation(for:)",
            as: ((NativeSwiftValue) async throws -> NativeSwiftValue).self,
            genericArguments: [.type(capability)], valueABIs: abis)))
        return try await unsafe get.unsafeInvoke(on: object, marker).copyUnderlyingValue()
    }

    /// The CoreDevice error that the capabilities' typed throws use.
    func errorSample() async throws -> any Error {
        let errorType = try await runtime.resolve(.swift(.type("CoreDevice.CoreDeviceError")))
        let sample = try await errorType.resolve(.swift(.staticGetter("ioError", as: (() -> NativeSwiftValue).self,
            valueABIs: [errorType: try .opaque(named: errorType.name)])))
        guard let failure = try unsafe sample.unsafeInvoke().withCopy({ $0 as? any Error }) else {
            throw NativeError("coredevice-error-type", "CoreDevice's error type could not be resolved.")
        }
        return failure
    }
}
