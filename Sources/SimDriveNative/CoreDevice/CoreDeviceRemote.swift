import ABIBridge
import Foundation

/// CoreDevice's device manager for default devices and simulators, created and initialized once per process.
@MainActor
enum CoreDeviceManager {
    private static let initializationLimit: Duration = .seconds(30)
    private static let manager = SharedInitialization(within: initializationLimit,
        timeout: SimDriveError(.coreDeviceTimeout, "CoreDevice did not finish starting in time; retry."),
        create)

    static func shared() async throws -> NativeSwiftValue {
        try await manager.value()
    }

    private static func create() async throws -> NativeSwiftValue {
        try await NativeFrameworks.load(NativeFrameworks.coreDevicePath)
        let (created, initialize) = try await ABIRuntime.shared.prepare { runtime in
            let service = try await runtime.resolve(.swift(.type("CoreDevice.CoreDeviceService")))
            let sharedConnection = try await service.resolve(.swift(.staticGetter("sharedConnection", as: (() -> NativeSwiftValue).self)))
            let connection = try unsafe sharedConnection.unsafeInvoke()
            let visibility = try await runtime.resolve(.swift(.type("CoreDevice.DeviceVisibilityClass")))
            let classes = try ["default", "simulators"].map { try visibility.makeEnumCase(named: $0) }
            let type = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
            let make = try await type.resolve(.swift(.initializer("init(serviceConnection:allowedDeviceVisibilityClasses:)",
                as: ((NativeSwiftValue, [NativeSwiftValue]) -> NativeSwiftValue).self)))
            let initialize = try await type.resolve(.swift(.method("awaitFullInitialization()", as: (() async -> Void).self)))
            return (try unsafe make.unsafeInvoke(connection, classes), initialize)
        }
        try await unsafe initialize.unsafeInvoke(on: created)
        return created
    }

    /// The CoreDevice identifier of the simulator `udid`; simulator UDIDs are not keys of `DeviceManager.devices`.
    static func simulatorIdentifier(udid: String) async throws -> UUID? {
        let manager = try await shared()
        let (devices, deviceInfo, readUDID) = try await ABIRuntime.shared.prepare { runtime in
            let managerType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
            let devices = try await managerType.resolve(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
            let remote = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
            let deviceInfo = try await remote.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
            let infoType = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
            let readUDID = try await infoType.resolve(.swift(.getter("udid", as: (() -> String?).self)))
            return (devices, deviceInfo, readUDID)
        }
        var match: UUID?
        for (identifier, object) in try unsafe devices.unsafeInvoke(on: manager) {
            let info = try unsafe deviceInfo.unsafeInvoke(on: object)
            if try unsafe readUDID.unsafeInvoke(on: info)?.caseInsensitiveCompare(udid) == .orderedSame {
                guard match == nil else {
                    throw SimDriveError(.coreDeviceIdentity, "More than one CoreDevice record matches the simulator \(udid).")
                }
                match = identifier
            }
        }
        return match
    }
}

/// A simulator's CoreDevice `RemoteDevice`, which serves its CoreDevice capabilities. One serves a whole session.
@MainActor
package final class CoreDeviceRemote {
    private static let connectionLimit: Duration = .seconds(5)
    private static let connectionPollInterval: Duration = .milliseconds(250)
    /// How long one capability call may take; they answer in milliseconds when CoreDevice works.
    private static let callLimit: Duration = .seconds(15)

    /// CoreDevice's identifier, which `DeviceManager.devices` is keyed by.
    package let identifier: UUID
    let runtime: ABIRuntime
    private let type: NativeSwiftType
    private let object: NativeSwiftValue
    private let supportsFeature: NativeSwiftMethod<(String) -> Bool>
    private var cachedErrorSample: (any Error)?
    /// Whether a call on this record went unanswered; its owner should open a new record.
    package private(set) var hasFailed = false

    /// The CoreDevice record of `device` once CoreDevice connects to it; until then its features read as absent.
    package static func open(device: SimulatorDevice) async throws -> CoreDeviceRemote {
        let deadline = ContinuousClock.now + connectionLimit
        var remote: CoreDeviceRemote?
        while true {
            if remote == nil, let identifier = try await CoreDeviceManager.simulatorIdentifier(udid: device.udid) {
                remote = try await CoreDeviceRemote(identifier: identifier)
            }
            if let remote, try await remote.isConnected() {
                return remote
            }
            guard ContinuousClock.now < deadline else {
                throw SimDriveError(.coreDeviceNotReady, remote == nil
                    ? "CoreDevice does not list \(device.name) yet; retry."
                    : "CoreDevice has not connected to \(device.name) yet; retry.")
            }
            try await Task.sleep(for: connectionPollInterval)
        }
    }

    /// A physical device's CoreDevice record, connected: CoreDevice opens its tunnel and enables its developer disk
    /// image's services on the way, which takes about a second the first time.
    package static func open(physical record: PhysicalDeviceRecord) async throws -> CoreDeviceRemote {
        let remote = try await CoreDeviceRemote(identifier: record.identifier)
        let connect = try await remote.type.resolve(.swift(.method("connect()", as: (() async throws -> Void).self)))
        do {
            try await remote.call("connect") { [object = remote.object] in try await unsafe connect.unsafeInvoke(on: object) }
        } catch let error as SimDriveError {
            throw error
        } catch {
            throw SimDriveError(.deviceNotConnected, "CoreDevice could not connect to \(record.name): \(error.localizedDescription) "
                                + "Check that it is unlocked, trusts this Mac and has Developer Mode on.")
        }
        return remote
    }

    /// A RemoteXPC connection to the device service of `feature`, an `OS_xpc_remote_connection` that handles its
    /// events on the main queue.
    func remoteConnection(to feature: String) async throws -> AnyObject {
        let open = try await type.resolve(.swift(.method(
            "remoteXPCConnection(toFeatureIdentifiedBy:connectionMode:handlingEventsOn:)",
            as: ((String, UInt64, DispatchQueue) async throws -> AnyObject).self)))
        return try await call("remoteXPCConnection") { [object] in
            try await unsafe open.unsafeInvoke(on: object, feature, Self.defaultConnectionMode, DispatchQueue.main)
        }
    }

    /// The mode CoreDevice's own callers pass; others are undocumented.
    private static let defaultConnectionMode: UInt64 = 0

    private init(identifier: UUID) async throws {
        let manager = try await CoreDeviceManager.shared()
        let runtime = ABIRuntime.shared
        let (object, type, supportsFeature) = try await runtime.prepare { runtime in
            let managerType = try await runtime.resolve(.swift(.type("CoreDevice.DeviceManager")))
            let devices = try await managerType.resolve(.swift(.getter("devices", as: (() -> [UUID: NativeSwiftValue]).self)))
            guard let object = try unsafe devices.unsafeInvoke(on: manager)[identifier] else {
                throw SimDriveError(.coreDeviceDevice, "CoreDevice no longer lists the device.")
            }
            let type = try await runtime.resolve(.swift(.type("CoreDevice.RemoteDevice")))
            let supportsFeature = try await type.resolve(.swift(.method("supportsFeature(identifiedBy:)", as: ((String) -> Bool).self)))
            return (object, type, supportsFeature)
        }
        self.identifier = identifier
        self.runtime = runtime
        self.object = object
        self.type = type
        self.supportsFeature = supportsFeature
    }

    func supports(_ feature: String) throws -> Bool {
        try unsafe supportsFeature.unsafeInvoke(on: object, feature)
    }

    private func isConnected() async throws -> Bool {
        let infoType = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceInfo")))
        let stateType = try await runtime.resolve(.swift(.type("CoreDeviceProtocols.DeviceState")))
        let abis = try NativeType.opaqueABIs(for: [stateType])
        let deviceInfo = try await type.resolve(.swift(.getter("deviceInfo", as: (() -> NativeSwiftValue).self)))
        let state = try await infoType.resolve(.swift(.getter("state", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let rawValue = try await stateType.resolve(.swift(.getter("rawValue", as: (() -> String).self,
            valueABIs: abis, receiverABI: abis[stateType])))
        let connected = try stateType.makeEnumCase(named: "connected")
        let info = try unsafe deviceInfo.unsafeInvoke(on: object)
        return try unsafe rawValue.unsafeInvoke(on: state.unsafeInvoke(on: info)) == rawValue.unsafeInvoke(on: connected)
    }

    func implementation(capability name: String, feature: String) async throws -> NativeSwiftValue {
        guard try supports(feature) else {
            throw SimDriveError(.coreDeviceCapability, "The device does not expose \(feature).")
        }
        let capability = try await runtime.resolve(.swift(.type("CoreDevice." + name)))
        let markerType = try await runtime.resolve(.swift(.type("CoreDevice.CapabilityStaticMember", genericArguments: [.type(capability)])))
        let abis = try NativeType.opaqueABIs(for: [markerType])
        let make = try await markerType.resolve(.swift(.initializer("init()", as: (() -> NativeSwiftValue).self, valueABIs: abis)))
        let marker = try unsafe make.unsafeInvoke()
        let get = try await type.resolve(.swift(.method("getImplementation(for:)",
            as: ((NativeSwiftValue) async throws -> NativeSwiftValue).self,
            genericArguments: [.type(capability)], valueABIs: abis)))
        return try await call("getImplementation") { [object] in
            try await unsafe get.unsafeInvoke(on: object, marker).copyUnderlyingValue()
        }
    }

    /// Runs a CoreDevice call that a stalled CoreDeviceService may never answer, failing with `coredevice-timeout`
    /// after `callLimit`. A record with an unanswered call counts as failed.
    func call<Value>(_ name: String, _ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let timeout = SimDriveError(.coreDeviceTimeout, "CoreDevice did not answer \(name) within "
                                    + "\(Self.callLimit.components.seconds) s; retry.")
        do {
            return try await withTimeLimit(Self.callLimit, timeout: timeout, operation)
        } catch let error as SimDriveError where error == timeout {
            hasFailed = true
            throw error
        }
    }

    /// A value of the CoreDevice error type that the capabilities' typed throws use, which binding them needs.
    func errorSample() async throws -> any Error {
        if let cachedErrorSample { return cachedErrorSample }
        let errorType = try await runtime.resolve(.swift(.type("CoreDevice.CoreDeviceError")))
        let sample = try await errorType.resolve(.swift(.staticGetter("ioError", as: (() -> NativeSwiftValue).self,
            valueABIs: try NativeType.opaqueABIs(for: [errorType]))))
        guard let failure = try unsafe sample.unsafeInvoke().withCopy({ $0 as? any Error }) else {
            throw SimDriveError(.coreDeviceErrorType, "CoreDevice's error type could not be resolved.")
        }
        cachedErrorSample = failure
        return failure
    }
}
