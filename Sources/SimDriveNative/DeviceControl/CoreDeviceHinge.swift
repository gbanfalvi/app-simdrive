import ABIBridge
import Foundation
import IOKit

/// A foldable's posture, named as the command line spells it.
package enum DevicePosture: String, CaseIterable, Sendable {
    case closed, partiallyOpen = "half", open

    /// The hinge settles near, not at, the angle it is sent, so each posture spans a range of angles.
    private static let closedLimit = 15.0
    private static let openLimit = 175.0

    /// The angle in degrees that sets the posture.
    var degrees: Double {
        switch self {
        case .closed: 0
        case .partiallyOpen: 130
        case .open: 180
        }
    }

    /// The posture a hinge angle in degrees confirms.
    package init?(angle: Double?) {
        guard let angle, angle.isFinite else { return nil }
        if angle < Self.closedLimit {
            self = .closed
        } else if angle > Self.openLimit {
            self = .open
        } else {
            self = .partiallyOpen
        }
    }
}

/// Reads and sets a foldable simulator's hinge through CoreDevice's motion and vendor-defined HID capabilities.
@MainActor
package final class CoreDeviceHinge {
    private static let motionFeature = "com.apple.coredevice.feature.monitormotion"
    private static let vendorFeature = "com.apple.coredevice.feature.remote.hid.vendordefined"
    private static let features: Set<String> = [vendorFeature, motionFeature, GuestHIDService.universalHIDFeature]
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
    private var vendorSend: (@MainActor (Data) throws -> Void)?

    /// The hinge of `remote`'s device, or nil when it has none.
    package static func open(remote: CoreDeviceRemote) async throws -> CoreDeviceHinge? {
        let model = try await remote.hardwareModel()?.lowercased() ?? ""
        let supported = try features.allSatisfy { try remote.supports($0) }
        guard hardwareModels.contains(model), supported else { return nil }
        let implementation = try await remote.implementation(capability: "MonitorMotionCapability", feature: motionFeature)
        return try await open(remote: remote, implementation: implementation, failure: try await remote.errorSample())
    }

    private static func open<Failure: Error>(remote: CoreDeviceRemote, implementation: NativeSwiftValue,
                                            failure: Failure) async throws -> CoreDeviceHinge? {
        let getMotion = try await implementation.type.resolve(.swift(.method("CoreDevice.MonitorMotionProtocol.motionManager()",
            as: (() async throws(Failure) -> NativeSwiftValue).self)))
        let motion = try await unsafe getMotion.unsafeInvoke(on: implementation)
        let supportsHinge = try await motion.type.resolve(.swift(.getter("supportsHingeAngle", as: (() -> Bool).self)))
        guard try unsafe supportsHinge.unsafeInvoke(on: motion) else { return nil }
        return try await remote.runtime.prepare { _ in
            try await CoreDeviceHinge(remote: remote, motion: motion, failure: failure)
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
        let abis = try NativeType.opaqueABIs(for: [snapshot, configuration, sequence, measurement])
        let makeConfig = try await configuration.resolve(.swift(.initializer("init(changeThreshold:updateInterval:)",
            as: ((Measurement<UnitAngle>, Duration) -> NativeSwiftValue).self, valueABIs: abis)))
        config = try unsafe makeConfig.unsafeInvoke(Self.changeThreshold, Self.updateInterval)
        let monitor = try await motion.type.resolve(.swift(.method("monitorHingeAngle(config:)",
            as: ((NativeSwiftValue) async throws(Failure) -> NativeSwiftValue).self, valueABIs: abis)))
        self.monitor = { config in try await unsafe monitor.unsafeInvoke(on: motion, config) }
        let data = try await runtime.resolve(.swift(.type("Foundation.Data")))
        let dataABI = try NativeType.dataABI(data)
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
            throw SimDriveError(.hingeObservation, "The device's hinge angle could not be observed.")
        }
        try await observe(sequence, update: update)
    }

    private func observe<S: AsyncSequence>(_ sequence: S, update: @MainActor (Double?) -> Void) async throws {
        var iterator = sequence.makeAsyncIterator()
        while let batch = try await iterator.next(isolation: #isolation) {
            try Task.checkCancellation()
            guard let snapshots = batch as? [Any] else {
                throw SimDriveError(.hingeSnapshot, "The device sent an unexpected hinge angle snapshot.")
            }
            guard let snapshot = snapshots.last, try unsafe isValid.unsafeInvoke(on: snapshot) else {
                update(nil)
                continue
            }
            let angle = try unsafe readAngle.unsafeInvoke(on: snapshot).converted(to: .degrees).value
            update(angle.isFinite ? angle : nil)
        }
    }

    /// Starts moving the hinge toward `posture`; the angle observation shows its progress.
    package func send(_ posture: DevicePosture) async throws {
        let send = try await vendorSender()
        do {
            try send(Self.serialize(posture))
        } catch {
            vendorSend = nil
            throw error
        }
    }

    private func vendorSender() async throws -> @MainActor (Data) throws -> Void {
        if let vendorSend { return vendorSend }
        let implementation = try await remote.implementation(capability: "VendorDefinedHIDCapability", feature: Self.vendorFeature)
        let send = try await prepareVendorSend(implementation)
        vendorSend = send
        return send
    }

    private static func serialize(_ posture: DevicePosture) throws -> Data {
        let dictionary: [String: Any] = ["provider": "com.apple.Virtualization.VirtualMachines",
            "source": "hinge-slider-control", "type": "range", "value": posture.degrees]
        guard let data = IOCFSerialize(dictionary as CFDictionary, CFOptionFlags(kIOCFSerializeToBinary)) else {
            throw SimDriveError(.hingePayload, "The hinge command could not be serialized.")
        }
        return data as Data
    }
}
