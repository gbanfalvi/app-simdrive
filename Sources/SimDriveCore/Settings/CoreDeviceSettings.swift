import Foundation
import SimDriveNative

/// The settings the guest applies through CoreDevice's setting actions, which simulators share with devices. Each maps
/// between a catalog value and its action's input and output, as JSON objects.
enum CoreDeviceSetting: String, Equatable, Sendable {
    case voiceOver, colorFilter, colorFilterIntensity

    static let colorFilterTypes = ["grayscale", "protanopia", "deuteranopia", "tritanopia"]
    static let colorFilterOff = "off"
    /// The guest refuses an intensity for grayscale, which has none.
    private static let typesWithoutIntensity: Set = ["grayscale"]

    /// The guest setting whose action reads and changes the value.
    var action: GuestSetting {
        switch self {
        case .voiceOver: .voiceOver
        case .colorFilter, .colorFilterIntensity: .colorFilter
        }
    }

    /// The setting's value in its action's output.
    func value(in output: [String: Any]) -> JSONValue {
        switch self {
        case .voiceOver:
            let configuration = output["voiceOverConfiguration"] as? [String: Any]
            return (configuration?["enabled"] as? Bool).map(JSONValue.bool) ?? .unsupported
        case .colorFilter:
            guard let filter = output["colorFilter"] as? [String: Any], let enabled = filter["enabled"] as? Bool else { return .unsupported }
            guard enabled else { return .string(Self.colorFilterOff) }
            let name = ((filter["filterType"] as? [String: Any])?["name"] as? String)?.lowercased()
            return name.map(JSONValue.string) ?? .unsupported
        case .colorFilterIntensity:
            guard let filter = output["colorFilter"] as? [String: Any] else { return .unsupported }
            return (filter["intensity"] as? Double).map(JSONValue.number) ?? .null
        }
    }

    /// What setting a value needs besides the value: the current output, and the native filter type of a name.
    @MainActor
    struct Context {
        var current: [String: Any] = [:]
        var filterType: @MainActor (String) async throws -> Any = { $0 }
    }

    /// Whether setting a value needs the current output first: the color filter's input carries type and intensity together.
    var needsCurrentValue: Bool { action == .colorFilter }

    /// The action input that sets the value, or nil when the setting does not take the value, or cannot from the
    /// current state.
    @MainActor
    func input(for value: JSONValue, in context: Context = Context()) async throws -> [String: Any]? {
        switch (self, value) {
        case (.voiceOver, .bool(let isOn)):
            return ["voiceOverConfiguration": ["enabled": isOn]]
        case (.colorFilter, .string(Self.colorFilterOff)):
            return ["colorFilter": ["enabled": false]]
        case (.colorFilter, .string(let type)) where Self.colorFilterTypes.contains(type):
            return try await Self.filter(type, intensity: Self.colorFilterIntensity.value(in: context.current), context: context)
        case (.colorFilterIntensity, .number(let intensity)):
            guard case .string(let type) = Self.colorFilter.value(in: context.current), Self.colorFilterTypes.contains(type),
                  !Self.typesWithoutIntensity.contains(type) else { return nil }
            return try await Self.filter(type, intensity: .number(intensity), context: context)
        default:
            return nil
        }
    }

    /// A filter of `type`, keeping `intensity` where the type has one.
    @MainActor
    private static func filter(_ type: String, intensity: JSONValue, context: Context) async throws -> [String: Any] {
        var filter: [String: Any] = ["enabled": true, "filterType": try await context.filterType(type)]
        if !typesWithoutIntensity.contains(type), case .number(let level) = intensity { filter["intensity"] = level }
        return ["colorFilter": filter]
    }
}
