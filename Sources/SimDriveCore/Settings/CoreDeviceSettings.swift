import Foundation
import SimDriveNative

/// The settings the guest applies through CoreDevice's setting actions, which simulators share with devices. Each maps
/// between a catalog value and its action's input and output, as JSON objects.
enum CoreDeviceSetting: String, Equatable, Sendable {
    case voiceOver, colorFilter, colorFilterIntensity
    /// Kept by CoreSimulator on a simulator, so reached through these actions on physical devices only.
    case appearance, textSize, increaseContrast, reduceMotion, reduceTransparency

    static let colorFilterTypes = ["grayscale", "protanopia", "deuteranopia", "tritanopia"]
    static let colorFilterOff = "off"
    /// The guest refuses an intensity for grayscale, which has none.
    private static let typesWithoutIntensity: Set = ["grayscale"]

    /// The guest setting whose action reads and changes the value.
    var action: GuestSetting {
        switch self {
        case .voiceOver: .voiceOver
        case .colorFilter, .colorFilterIntensity: .colorFilter
        case .appearance: .userInterfaceStyle
        case .textSize: .textSize
        case .increaseContrast: .increaseContrast
        case .reduceMotion: .reduceMotion
        case .reduceTransparency: .reduceTransparency
        }
    }

    /// The key of a toggle action's `{"enabled": Bool}` object, in its input and output.
    private var toggleKey: String? {
        switch self {
        case .increaseContrast: "increaseContrast"
        case .reduceMotion: "reduceMotion"
        case .reduceTransparency: "reduceTransparency"
        default: nil
        }
    }

    /// A text size as the catalog names it, `accessibility-extra-large`, from CoreDevice's case name, `accessibilityExtraLarge`.
    static func textSizeName(ofCase name: String) -> String {
        name.reduce(into: "") { result, character in
            if character.isUppercase { result += "-" + character.lowercased() } else { result.append(character) }
        }
    }

    /// The inverse of `textSizeName(ofCase:)`.
    static func textSizeCase(ofName name: String) -> String {
        name.split(separator: "-").enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
    }

    /// The setting's value in its action's output.
    func value(in output: [String: Any]) -> JSONValue {
        if let toggleKey {
            return ((output[toggleKey] as? [String: Any])?["enabled"] as? Bool).map(JSONValue.bool) ?? .unsupported
        }
        switch self {
        case .appearance:
            return (output["style"] as? String).map(JSONValue.string) ?? .unsupported
        case .textSize:
            let size = (output["textSize"] as? [String: Any])?["size"] as? [String: Any]
            return size?.keys.first.map { .string(Self.textSizeName(ofCase: $0)) } ?? .unsupported
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
        case .increaseContrast, .reduceMotion, .reduceTransparency:
            return .unsupported
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
        if let toggleKey {
            guard case .bool(let isOn) = value else { return nil }
            return [toggleKey: ["enabled": isOn]]
        }
        switch (self, value) {
        case (.appearance, .string(let style)):
            return ["style": style]
        case (.textSize, .string(let size)):
            return ["textSize": ["size": [Self.textSizeCase(ofName: size): [String: Any]()]]]
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
