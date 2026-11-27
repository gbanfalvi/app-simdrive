import ABIBridge
import Foundation

/// A setting the guest applies itself, as the Settings app does, through a CoreDevice action pair.
package enum GuestSetting: String, CaseIterable, Sendable {
    case voiceOver = "VoiceOver"
    case colorFilter = "ColorFilter"
    case reduceMotion = "ReduceMotion"
    case showBorders = "ShowBorders"
    case reduceTransparency = "ReduceTransparency"
    case userInterfaceStyle = "UserInterfaceStyle"
    case textSize = "DeviceTextSize"
    case increaseContrast = "DeviceIncreaseContrast"

    var get: GuestActions.Declaration { GuestActions.Declaration("Get\(rawValue)ActionDeclaration", readsOutput: true) }
    var set: GuestActions.Declaration { GuestActions.Declaration("Set\(rawValue)ActionDeclaration", readsOutput: false) }
}

/// Reads and changes guest settings through CoreDevice's setting actions, on simulators and physical devices alike.
@MainActor
package final class GuestSettingActions {
    private let actions: GuestActions

    private init(guest: Guest) {
        actions = GuestActions(guest: guest)
    }

    package static func open(guest: Guest) -> GuestSettingActions {
        GuestSettingActions(guest: guest)
    }

    /// Whether the guest has the service that performs the setting's actions.
    package func supports(_ setting: GuestSetting) async throws -> Bool {
        try await actions.supports(setting.set)
    }

    /// The setting's current value, as its Get action's output encodes to JSON.
    package func value(of setting: GuestSetting) async throws -> [String: Any] {
        try await perform(setting.get, input: [:])
    }

    /// Applies `input`, the JSON of the setting's Set action input.
    package func set(_ setting: GuestSetting, input: [String: Any]) async throws {
        _ = try await perform(setting.set, input: input)
    }

    /// The JSON of a `DeviceColorFilter.FilterType` member, such as `deuteranopia`, as the color filter's input takes it.
    package func colorFilterType(_ member: String) async throws -> Any {
        let type = try await ABIRuntime.shared.resolve(.swift(.type("CoreDeviceUtilities.DeviceColorFilter.FilterType")))
        let getter = try await type.resolve(.swift(.staticGetter(member, as: (() -> NativeSwiftValue).self,
            valueABIs: [type: try .opaque(named: type.name)])))
        return try JSONSerialization.jsonObject(with: GuestActions.json(of: unsafe getter.unsafeInvoke()))
    }

    private func perform(_ declaration: GuestActions.Declaration, input: [String: Any]) async throws -> [String: Any] {
        do { return try await actions.perform(declaration, input: input) } catch let refusal as GuestActionRefusal {
            throw SimDriveError(.guestSetting, "The guest refused the setting (CoreDevice error \(refusal.code)): \(refusal.reason)")
        }
    }
}
