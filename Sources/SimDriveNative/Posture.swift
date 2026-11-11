import ABIBridge
import Foundation
import IOKit

package enum DevicePosture: String, CaseIterable, Sendable {
    case closed, partiallyOpen, open

    private static let closedLimit = 15.0
    private static let openLimit = 175.0
    package var degrees: Double {
        switch self {
        case .closed: 0
        case .partiallyOpen: 130
        case .open: 180
        }
    }

    /// The posture a hinge angle confirms.
    package static func confirmed(angle: Double?) -> DevicePosture? {
        guard let angle, angle.isFinite else { return nil }
        if angle < closedLimit { return .closed }
        if angle > openLimit { return .open }
        return .partiallyOpen
    }
}

/// Reads and sets a foldable simulator's hinge through CoreDevice's motion and vendor-defined HID services.
@MainActor
package final class PostureTransport {
    private static let motionFeature = "com.apple.coredevice.feature.monitormotion"
    private static let vendorFeature = "com.apple.coredevice.feature.remote.hid.vendordefined"
    private static let features: Set<String> = [vendorFeature, motionFeature, HIDService.universalHIDFeature]
    private static let hardwareModels: Set<String> = ["v68", "v68ap", "v68dev"]
    private static let hingeUsagePage: UInt16 = 0xFF61
    private static let hingeUsage: UInt16 = 0x5B
    private static let hingeReportVersion: UInt32 = 0
    private static let changeThreshold = Measurement(value: 0.01, unit: UnitAngle.degrees)
    private static let updateInterval: Duration = .milliseconds(50)

    private let remote: CoreDeviceRemote
    private let config: NativeSwiftValue
    private let monitor: @MainActor (NativeSwiftValue) async throws -> NativeSwiftValue
    private let prepareVendorSend: @MainActor (NativeSwiftValue) async throws -> (@MainActor (Data) throws -> Void)
    private let isValid: NativeSwiftMethod<() -> Bool>
    private let readAngle: NativeSwiftMethod<() -> Measurement<UnitAngle>>

    /// The hinge of the simulator `udid`, or nil when the device has none.
    package static func make(udid: String) async throws -> PostureTransport? {
        guard let identifier = try await CoreDeviceRuntime.simulatorIdentifier(udid: udid) else { return nil }
        let remote = try await CoreDeviceRemote(identifier: identifier)
        let model = try await remote.hardwareModel()?.lowercased() ?? ""
        let supported = try features.allSatisfy { try remote.supports($0) }
        guard hardwareModels.contains(model), supported else { return nil }
        let implementation = try await remote.implementation(capability: "MonitorMotionCapability", feature: motionFeature)
        return try await make(remote: remote, implementation: implementation, failure: try await remote.errorSample())
    }

    private static func make<Failure: Error>(remote: CoreDeviceRemote, implementation: NativeSwiftValue,
                                            failure: Failure) async throws -> PostureTransport? {
        let getMotion = try await implementation.type.resolve(.swift(.method("CoreDevice.MonitorMotionProtocol.motionManager()",
            as: (() async throws(Failure) -> NativeSwiftValue).self)))
        let motion = try await unsafe getMotion.unsafeInvoke(on: implementation)
        let supportsHinge = try await motion.type.resolve(.swift(.getter("supportsHingeAngle", as: (() -> Bool).self)))
        guard try unsafe supportsHinge.unsafeInvoke(on: motion) else { return nil }
        return try await remote.runtime.prepare { _ in
            try await PostureTransport(remote: remote, motion: motion, failure: failure)
        }
    }

    private init<Failure: Error>(remote: CoreDeviceRemote, motion: NativeSwiftValue, failure: Failure) async throws {
        self.remote = remote
        let runtime = remote.runtime
        let snapshot = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.DeviceHingeAngleSnapshot")))
        let configuration = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.HingeAngleStreamConfig")))
        let array = try await runtime.resolve(.swift(.type("Swift.Array", genericArguments: [.type(snapshot)])))
        let arguments: [NativeSwiftGenericArgument] = [.type(array), .type((any Error).self)]
        let sequence = try await runtime.resolve(.swift(.type("Swift.AsyncThrowingStream", genericArguments: arguments)))
        let measurement = try await runtime.resolve(.swift(.type("Foundation.Measurement", genericArguments: [.type(UnitAngle.self)])))
        let abis = try Dictionary(uniqueKeysWithValues: [snapshot, configuration, sequence, measurement]
            .map { ($0, try NativeType.opaque(named: $0.name)) })
        let makeConfig = try await configuration.resolve(.swift(.initializer("init(changeThreshold:updateInterval:)",
            as: ((Measurement<UnitAngle>, Duration) -> NativeSwiftValue).self, valueABIs: abis)))
        config = try unsafe makeConfig.unsafeInvoke(Self.changeThreshold, Self.updateInterval)
        let monitor = try await motion.type.resolve(.swift(.method("monitorHingeAngle(config:)",
            as: ((NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
        self.monitor = { config in try await unsafe monitor.unsafeInvoke(on: motion, config) }
        let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
        // Data is @frozen; Device Hub passes its two words in integer registers.
        let dataABI = try NativeType.structure(named: data.name, fields: [.uint64, .uint64])
        prepareVendorSend = { implementation in
            let send = try await implementation.type.resolve(.swift(.method("CoreDevice.HIDVendorDefined.send(usagePage:usage:version:data:)",
                as: ((UInt16, UInt16, UInt32, Data) throws(Failure) -> Void).self, valueABIs: [data: dataABI])))
            return { data in try unsafe send.unsafeInvoke(on: implementation, Self.hingeUsagePage, Self.hingeUsage, Self.hingeReportVersion, data) }
        }
        isValid = try await snapshot.resolve(.swift(.getter("isAngleValid", as: (() -> Bool).self, valueABIs: abis)))
        readAngle = try await snapshot.resolve(.swift(.getter("angle", as: (() -> Measurement<UnitAngle>).self, valueABIs: abis)))
    }

    /// Calls `update` with each hinge angle in degrees, or nil when the device reports none, until cancelled.
    package func observe(_ update: @escaping @MainActor (Double?) -> Void) async throws {
        let owner = try await monitor(config)
        defer { withExtendedLifetime(owner) {} }
        guard let sequence = try owner.withCopy({ $0 as? any AsyncSequence }) else {
            throw NativeError("posture-observation", "The device's hinge angle could not be observed.")
        }
        try await observe(sequence, update: update)
    }

    private func observe<S: AsyncSequence>(_ sequence: S, update: @MainActor (Double?) -> Void) async throws {
        var iterator = sequence.makeAsyncIterator()
        while let batch = try await iterator.next(isolation: #isolation) {
            try Task.checkCancellation()
            guard let snapshots = batch as? [Any] else {
                throw NativeError("posture-snapshot", "The device sent an unexpected hinge angle snapshot.")
            }
            guard let snapshot = snapshots.last, try unsafe isValid.unsafeInvoke(on: snapshot) else {
                update(nil)
                continue
            }
            let angle = try unsafe readAngle.unsafeInvoke(on: snapshot).converted(to: .degrees).value
            update(angle.isFinite ? angle : nil)
        }
    }

    package func send(_ posture: DevicePosture) async throws {
        let implementation = try await remote.implementation(capability: "VendorDefinedHIDCapability", feature: Self.vendorFeature)
        let send = try await prepareVendorSend(implementation)
        try send(Self.serialize(posture))
    }

    private static func serialize(_ posture: DevicePosture) throws -> Data {
        let dictionary: [String: Any] = ["provider": "com.apple.Virtualization.VirtualMachines",
            "source": "hinge-slider-control", "type": "range", "value": posture.degrees]
        guard let data = IOCFSerialize(dictionary as CFDictionary, CFOptionFlags(kIOCFSerializeToBinary)) else {
            throw NativeError("posture-payload", "The hinge command could not be serialized.")
        }
        return data as Data
    }
}
