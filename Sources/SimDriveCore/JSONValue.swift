import Foundation

/// A JSON value, for command results and the daemon protocol.
package enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// The value as a command-line argument: strings as they are, numbers without a trailing `.0`.
    package var argument: String? {
        switch self {
        case .string(let value): value
        case .number(let value): Int(exactly: value).map(String.init) ?? String(value)
        case .bool(let value): String(value)
        case .array, .object, .null: nil
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    package init(stringLiteral value: String) { self = .string(value) }
    package init(integerLiteral value: Int) { self = .number(Double(value)) }
    package init(floatLiteral value: Double) { self = .number(value) }
    package init(booleanLiteral value: Bool) { self = .bool(value) }
    package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    package init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }

    package init(_ value: String?) { self = value.map(JSONValue.string) ?? .null }
    package init(_ value: Double?) { self = value.map(JSONValue.number) ?? .null }
    package init(_ value: Int?) { self = value.map { .number(Double($0)) } ?? .null }
}

extension JSONEncoder {
    /// Compact, key-sorted output, one line per value.
    package static var line: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
