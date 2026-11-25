import ABIBridge
import XPC

/// Hardware and Apple TV Remote buttons, named as the command line spells them.
package enum HardwareButton: String, CaseIterable, Sendable {
    case home, lock, volumeUp = "volume-up", volumeDown = "volume-down", siri
    /// `keyboard` shows or hides the software keyboard; `screenshot` takes the guest's own screenshot; `action` presses an
    /// iPhone's Action button, by default toggling silent mode.
    case keyboard, screenshot, action
    case menu, select, playPause = "play-pause", up, down, left, right, channelUp = "channel-up", channelDown = "channel-down"

    private static let consumerPage: UInt16 = 0x0C
    private static let telephonyPage: UInt16 = 0x0B

    /// The Action button is on the telephony page; the rest are consumer controls.
    var usagePage: UInt16 { self == .action ? Self.telephonyPage : Self.consumerPage }

    /// Usages as the guest maps them, not as HID names them: Menu (0x40) is home, the TV button on tvOS; AC Home (0x223)
    /// is the remote's Menu (Back); Power (0x30) locks, or on tvOS opens Control Center. The newer ones are NeoSimulator's.
    var usage: UInt16 {
        switch self {
        case .keyboard: 0xB8
        case .screenshot: 0x65
        case .action: 0x2D
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

/// Presses a button and lets it go, as either of the guest's button routes does.
@MainActor
package protocol ButtonPresser: AnyObject {
    var hasFailed: Bool { get }
    func press(_ button: HardwareButton, hold: Duration) async throws
    func close() async
}

/// The guest's hardware buttons, which on an Apple TV are its remote's: a main-screen button service on the universal HID
/// service, sent CoreDevice's `CustomButtonReport`s, as Xcode 27.3 requires.
@MainActor
package final class GuestButtons: ButtonPresser {
    private let connection: GuestConnection
    private let service: GuestHIDService
    private let report: (UInt16, UInt16, Bool) throws -> NativeSwiftValue

    private init(connection: GuestConnection, service: GuestHIDService, report: @escaping (UInt16, UInt16, Bool) throws -> NativeSwiftValue) {
        self.connection = connection
        self.service = service
        self.report = report
    }

    /// Creates the guest's button service and waits until the guest takes its presses.
    package static func open(guest: SimulatorGuest) async throws -> GuestButtons {
        let runtime = ABIRuntime.shared
        let report = try await runtime.prepare { try await Self.reports(runtime: $0) }
        let descriptor = try await runtime.prepare { try await Self.mainScreenButtons(runtime: $0) }
        let connection = try await guest.connection(to: GuestHIDService.universalHIDFeature)
        let buttons = GuestButtons(connection: connection, service: try await connection.createService(descriptor), report: report)
        await pause(GuestInputTiming.settle)
        return buttons
    }

    package var hasFailed: Bool { connection.hasFailed }

    package func press(_ button: HardwareButton, hold: Duration) async throws {
        try service.send(report(button.usagePage, button.usage, true))
        await pause(hold)
        try service.send(report(button.usagePage, button.usage, false))
        try await connection.flush()
    }

    /// Removes the guest's button service, which releases a button it still holds.
    package func close() async {
        try? await service.remove()
        try? await connection.flush()
    }

    /// `CustomButtonReport(usage:down:).report`, an `HIDReport` of CoreDevice's own UniversalHID module.
    private static func reports(runtime: ABIRuntime) async throws -> (UInt16, UInt16, Bool) throws -> NativeSwiftValue {
        try await CoreDeviceUniversalHID.load()
        let usage = try CoreDeviceUniversalHID.type(named: "HIDUsage", runtime: runtime)
        let button = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.CustomButtonReport")))
        let report = try CoreDeviceUniversalHID.reportABI(runtime: runtime)
        let abis: [NativeSwiftType: NativeType] = [usage: try .structure(named: usage.name, fields: [.uint32]),
                                                  button: try .opaque(named: button.name), report.type: report.abi]
        let makeUsage = try await usage.resolve(.swift(.initializer("init(page:usage:)", as: ((Int, Int) -> NativeSwiftValue).self,
                                                                    valueABIs: abis)))
        let makeButton = try await button.resolve(.swift(.initializer("init(usage:down:)",
            as: ((NativeSwiftValue, Bool) -> NativeSwiftValue).self, valueABIs: abis)))
        let readReport = try await button.resolve(.swift(.getter("report", as: (() -> NativeSwiftValue).self, valueABIs: abis,
                                                                 receiverABI: abis[button])))
        return { page, usage, down in
            try unsafe readReport.unsafeInvoke(on: makeButton.unsafeInvoke(makeUsage.unsafeInvoke(Int(page), Int(usage)), down))
        }
    }

    /// The descriptor of `HIDServiceType.mainScreenButtons`, carrying that service type's ID.
    private static func mainScreenButtons(runtime: ABIRuntime) async throws -> NativeSwiftValue {
        let serviceType = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.HIDServiceType")))
        let descriptorType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceDescriptor")))
        let serviceIDType = try await runtime.resolve(.swift(.type("CoreDevice.HIDServiceID")))
        let abis: [NativeSwiftType: NativeType] = [serviceType: try .opaque(named: serviceType.name),
            descriptorType: try .opaque(named: descriptorType.name), serviceIDType: try .opaque(named: serviceIDType.name)]
        let makeDescriptor = try await serviceType.resolve(.swift(.method("descriptor()", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[serviceType])))
        let serviceID = try await serviceType.resolve(.swift(.getter("serviceID", as: (() -> NativeSwiftValue).self,
            valueABIs: abis, receiverABI: abis[serviceType])))
        let setServiceID = try await descriptorType.resolve(.swift(.setter("serviceID", as: ((NativeSwiftValue) -> Void).self,
            valueABIs: abis, receiverABI: abis[descriptorType])))
        let service = try serviceType.makeEnumCase(named: "mainScreenButtons")
        let descriptor = try unsafe makeDescriptor.unsafeInvoke(on: service)
        // descriptor() supplies the service's properties, with its ID unassigned.
        try unsafe setServiceID.unsafeInvoke(on: descriptor, serviceID.unsafeInvoke(on: service))
        return descriptor
    }
}

/// The guest's buttons through `remote.hid.button` and `IndigoButtonEvent`, the route before Xcode 27.3 removed that type.
/// Kept for `button --legacy`, in case the universal HID route misbehaves on an older runtime.
@MainActor
package final class LegacyGuestButtons: ButtonPresser {
    private static let feature = "com.apple.coredevice.feature.remote.hid.button"
    private let connection: GuestConnection
    private let event: (UInt16, UInt16, ButtonState) throws -> xpc_object_t

    private init(connection: GuestConnection, event: @escaping (UInt16, UInt16, ButtonState) throws -> xpc_object_t) {
        self.connection = connection
        self.event = event
    }

    /// Fails with `legacy-buttons-unavailable` on Xcode 27.3 and later.
    package static func open(guest: SimulatorGuest) async throws -> LegacyGuestButtons {
        let event = try await ABIRuntime.shared.prepare { try await GuestMessageCodec.indigoButtonEvents(runtime: $0) }
        return LegacyGuestButtons(connection: try await guest.connection(to: feature), event: event)
    }

    package var hasFailed: Bool { connection.hasFailed }

    package func press(_ button: HardwareButton, hold: Duration) async throws {
        try connection.post(.buttonEvent, encoded: event(button.usagePage, button.usage, .down))
        await pause(hold)
        try connection.post(.buttonEvent, encoded: event(button.usagePage, button.usage, .up))
        try await connection.flush()
    }

    package func close() async { await connection.drain() }
}
