import Foundation
import SimDriveNative

/// A value to write to a preference, with its `defaults` type.
enum PreferenceValue: Equatable, Sendable {
    case integer(Int)
    case float(Double)
    case string(String)

    var defaultsArguments: [String] {
        switch self {
        case .integer(let value): ["-int", String(value)]
        case .float(let value): ["-float", String(value)]
        case .string(let value): ["-string", value]
        }
    }
}

/// A simulator's guest preferences, through `defaults` run in the guest.
struct GuestPreferences: Sendable {
    private static let standardOutput = "-"

    let udid: String
    let tools: DeveloperTools

    /// A domain's numbers and strings, by key.
    func export(_ domain: String) async throws -> [String: JSONValue] {
        let result = try await tools.simctl(["spawn", udid, "defaults", "export", domain, Self.standardOutput])
        let output = Data(result.standardOutput.utf8)
        guard let values = try? PropertyListSerialization.propertyList(from: output, format: nil) as? [String: Any] else {
            throw SimDriveError(.guestPreferences, "defaults export \(domain) printed no property list.")
        }
        return values.compactMapValues(Self.json)
    }

    func write(_ value: PreferenceValue, forKey key: String, in domain: String) async throws {
        try await tools.simctl(["spawn", udid, "defaults", "write", domain, key] + value.defaultsArguments)
    }

    private static func json(_ value: Any) -> JSONValue? {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): .bool(number.boolValue)
        case let number as NSNumber: .number(number.doubleValue)
        case let string as String: .string(string)
        default: nil
        }
    }
}
