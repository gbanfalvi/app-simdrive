import ABIBridge
import Foundation

/// A physical device's backlight and passcode, through CoreDevice's display-info and lock-state capabilities.
@MainActor
package final class CoreDeviceDisplays {
    private static let displayInfoFeature = "com.apple.coredevice.feature.getdisplayinfo"
    private static let lockStateFeature = "com.apple.coredevice.feature.getlockstate"

    private let readBacklight: @MainActor () async throws -> String
    private let readPasscodeRequired: (@MainActor () async throws -> Bool)?

    private init(readBacklight: @escaping @MainActor () async throws -> String,
                 readPasscodeRequired: (@MainActor () async throws -> Bool)?) {
        self.readBacklight = readBacklight
        self.readPasscodeRequired = readPasscodeRequired
    }

    /// Nil when the device reports no display info.
    package static func open(remote: CoreDeviceRemote) async throws -> CoreDeviceDisplays? {
        guard try remote.supports(displayInfoFeature) else { return nil }
        let failure = try await remote.errorSample()
        return try await open(remote: remote, failure: failure)
    }

    private static func open<Failure: Error>(remote: CoreDeviceRemote, failure: Failure) async throws -> CoreDeviceDisplays {
        let runtime = remote.runtime
        let displays = try await remote.implementation(capability: "DisplayInfoCapability", feature: displayInfoFeature)
        let infoType = try await runtime.resolve(.swift(.type("CoreDevice.DisplayInfo")))
        let stateType = try await runtime.resolve(.swift(.type("CoreDevice.Display.BacklightState")))
        let abis = try NativeType.opaqueABIs(for: [infoType, stateType])
        let displayInfo = try await displays.type.resolve(.swift(.getter("CoreDevice.DisplayInfoProtocol.displayInfo",
            as: (() async throws(Failure) -> NativeSwiftValue).self,
            declaredAs: "() async throws(CoreDevice.CoreDeviceError) -> CoreDevice.DisplayInfo", valueABIs: abis)))
        let backlightState = try await infoType.resolve(.swift(.getter("backlightState", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[infoType])))
        let rawValue = try await stateType.resolve(.swift(.getter("rawValue", as: (() -> String).self, valueABIs: abis,
            receiverABI: abis[stateType])))
        let readBacklight: @MainActor () async throws -> String = {
            let info = try await remote.call("displayInfo") { try await unsafe displayInfo.unsafeInvoke(on: displays) }
            return try unsafe rawValue.unsafeInvoke(on: backlightState.unsafeInvoke(on: info))
        }
        guard try remote.supports(lockStateFeature) else { return CoreDeviceDisplays(readBacklight: readBacklight, readPasscodeRequired: nil) }
        let locks = try await remote.implementation(capability: "LockStateCapability", feature: lockStateFeature)
        let lockType = try await runtime.resolve(.swift(.type("CoreDevice.LockState")))
        let lockABIs = try NativeType.opaqueABIs(for: [lockType])
        let currentLockState = try await locks.type.resolve(.swift(.getter("CoreDevice.LockStateProtocol.currentLockState",
            as: (() async throws(Failure) -> NativeSwiftValue).self,
            declaredAs: "() async throws(CoreDevice.CoreDeviceError) -> CoreDevice.LockState", valueABIs: lockABIs)))
        let passcodeRequired = try await lockType.resolve(.swift(.getter("isPasscodeRequired", as: (() -> Bool).self,
            valueABIs: lockABIs, receiverABI: lockABIs[lockType])))
        return CoreDeviceDisplays(readBacklight: readBacklight, readPasscodeRequired: {
            let state = try await remote.call("currentLockState") { try await unsafe currentLockState.unsafeInvoke(on: locks) }
            return try unsafe passcodeRequired.unsafeInvoke(on: state)
        })
    }

    /// The main display's backlight. CoreDevice's `activeOn` is lit and `activeDimmed` dimmed; `inactiveOn`, an always-on
    /// display's sleep, drops input as a dimmed one does.
    package func backlight() async throws -> Backlight {
        switch try await readBacklight() {
        case "activeOn": .on
        case "activeDimmed", "inactiveOn": .dimmed
        case "off": .off
        default: .unknown
        }
    }

    /// Whether unlocking needs a passcode, which simdrive never types; nil when the device does not say.
    package func isPasscodeRequired() async throws -> Bool? {
        try await readPasscodeRequired?()
    }
}
