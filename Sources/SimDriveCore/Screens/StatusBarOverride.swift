import Foundation
import SimDriveNative

/// Status bar values to show instead of the real ones, by simdrive's option names, each checked against what
/// `simctl status_bar` accepts.
struct StatusBarOverride: Equatable, Sendable {
    private enum Accepts {
        case text
        case oneOf([String])
        case range(ClosedRange<Int>)

        func allows(_ value: String) -> Bool {
            switch self {
            case .text: true
            case .oneOf(let values): values.contains(value)
            case .range(let range): Int(value).map(range.contains) ?? false
            }
        }

        var description: String {
            switch self {
            case .text: "any text"
            case .oneOf(let values): values.joined(separator: ", ")
            case .range(let range): "\(range.lowerBound)-\(range.upperBound)"
            }
        }
    }

    /// simdrive's option, `simctl`'s flag, and what it accepts, in the order the flags are passed.
    private static let fields: [(option: String, flag: String, accepts: Accepts)] = [
        ("time", "--time", .text),
        ("battery", "--batteryLevel", .range(0...100)),
        ("battery-state", "--batteryState", .oneOf(["charging", "charged", "discharging"])),
        ("data-network", "--dataNetwork", .oneOf(["hide", "wifi", "3g", "4g", "lte", "lte-a", "lte+", "5g", "5g+", "5g-uwb", "5g-uc"])),
        ("wifi-mode", "--wifiMode", .oneOf(["searching", "failed", "active"])),
        ("wifi-bars", "--wifiBars", .range(0...3)),
        ("cellular-mode", "--cellularMode", .oneOf(["notSupported", "searching", "failed", "active"])),
        ("cellular-bars", "--cellularBars", .range(0...4)),
        ("operator", "--operatorName", .text),
    ]

    static var options: Set<String> { Set(fields.map(\.option)) }

    /// By option name, such as `battery` to `100`.
    let values: [String: String]

    /// Fails with a usage error for an unknown option, a value it does not accept, or no values at all.
    init(_ values: [String: String]) throws {
        guard !values.isEmpty else {
            throw SimDriveError.usage("status-bar override needs at least one of --"
                                      + Self.fields.map(\.option).joined(separator: ", --"))
        }
        for (option, value) in values {
            guard let field = Self.fields.first(where: { $0.option == option }) else {
                throw SimDriveError.usage("Unknown status bar option --\(option)")
            }
            guard field.accepts.allows(value) else {
                throw SimDriveError.usage("--\(option) takes \(field.accepts.description), not \(value)")
            }
        }
        self.values = values
    }

    /// `simctl status_bar override`'s flags, in a fixed order.
    var simctlArguments: [String] {
        Self.fields.flatMap { field in values[field.option].map { [field.flag, $0] } ?? [] }
    }
}
