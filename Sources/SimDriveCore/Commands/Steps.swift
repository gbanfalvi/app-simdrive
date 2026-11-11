import Foundation

/// Step files: a JSON array whose elements are argument arrays or command strings.
enum Steps {
    static func parse(_ data: Data) throws -> [[String]] {
        guard let values = try? JSONDecoder().decode([JSONValue].self, from: data) else {
            throw UsageError("Steps must be a JSON array")
        }
        return try values.enumerated().map { index, value in
            switch value {
            case .string(let line): return try tokenize(line)
            case .array(let elements):
                return try elements.map { element in
                    guard let argument = element.argument else { throw UsageError("Step \(index + 1) has a non-scalar argument") }
                    return argument
                }
            default: throw UsageError("Step \(index + 1) is neither a string nor an array")
            }
        }
    }

    /// Splits a command line on whitespace, keeping single- or double-quoted text together.
    static func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken { tokens.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        guard quote == nil else { throw UsageError("Unterminated quote in \"\(line)\"") }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
