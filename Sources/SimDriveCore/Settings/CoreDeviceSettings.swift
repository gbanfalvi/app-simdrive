import Foundation

/// The settings that `xcrun devicectl` reads and changes through CoreDevice, which simulators share with devices:
/// `device info appearance|voiceover` reads them, and `device settings appearance|voiceover` sets them.
enum CoreDeviceSetting: String, Equatable, Sendable {
    case voiceOver, colorFilter, colorFilterIntensity

    /// What `device info` to query for the setting's value.
    enum Source: String, CaseIterable, Sendable {
        case appearance, voiceover
    }

    static let colorFilterTypes = ["grayscale", "protanopia", "deuteranopia", "tritanopia"]
    static let colorFilterOff = "off"

    var source: Source {
        switch self {
        case .voiceOver: .voiceover
        case .colorFilter, .colorFilterIntensity: .appearance
        }
    }

    /// The setting's value in the result of `device info <source>`.
    func value(in result: [String: Any]) -> JSONValue {
        switch self {
        case .voiceOver:
            return (result["enabled"] as? Bool).map(JSONValue.bool) ?? .unsupported
        case .colorFilter:
            guard let filter = result["colorFilter"] as? [String: Any], let enabled = filter["enabled"] as? Bool else { return .unsupported }
            guard enabled else { return .string(Self.colorFilterOff) }
            let name = ((filter["filterType"] as? [String: Any])?["name"] as? String)?.lowercased()
            return name.map(JSONValue.string) ?? .unsupported
        case .colorFilterIntensity:
            guard let filter = result["colorFilter"] as? [String: Any] else { return .unsupported }
            return (filter["intensity"] as? Double).map(JSONValue.number) ?? .null
        }
    }

    /// Whether setting a value needs the current `device info` result first: `devicectl` takes an intensity only with a type.
    var needsCurrentValue: Bool { self == .colorFilterIntensity }

    /// The `devicectl` arguments that set the value, after `device settings`, given the current result of `device info` for
    /// settings that need it. Nil when the setting does not take the value, or cannot from the current state.
    func arguments(for value: JSONValue, current: [String: Any] = [:]) -> [String]? {
        switch (self, value) {
        case (.voiceOver, .bool(let isOn)):
            return ["voiceover", isOn ? "--enable" : "--disable"]
        case (.colorFilter, .string(Self.colorFilterOff)):
            return ["appearance", "--color-filter", "off"]
        case (.colorFilter, .string(let type)) where Self.colorFilterTypes.contains(type):
            return ["appearance", "--color-filter", "on", "--color-filter-type", type]
        case (.colorFilterIntensity, .number(let intensity)):
            guard case .string(let type) = Self.colorFilter.value(in: current), Self.colorFilterTypes.contains(type) else { return nil }
            return ["appearance", "--color-filter", "on", "--color-filter-type", type, "--color-filter-intensity", String(intensity)]
        default:
            return nil
        }
    }
}
