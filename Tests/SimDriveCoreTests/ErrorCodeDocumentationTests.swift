import Foundation
import Testing

/// Agents branch on error codes and on `retry`, so the README's table must list every code the sources declare, with the
/// same retry answer.
struct ErrorCodeDocumentationTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    private static let declaration = try! NSRegularExpression(pattern: #"ErrorCode\(rawValue: "([a-z-]+)"(, retryable: true)?"#)
    private static let codeInCell = try! NSRegularExpression(pattern: #"`([a-z-]+)`"#)

    /// Each declared code, and whether it is retryable.
    private static func declaredCodes() throws -> [String: Bool] {
        var codes: [String: Bool] = [:]
        let sources = repository.appendingPathComponent("Sources")
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in declaration.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let code = String(text[Range(match.range(at: 1), in: text)!])
                codes[code] = match.range(at: 2).location != NSNotFound
            }
        }
        return codes
    }

    /// Each code in the README's error table, and its retry column.
    private static func documentedCodes() throws -> [String: String] {
        let readme = try String(contentsOf: repository.appendingPathComponent("README.md"), encoding: .utf8)
        guard let table = readme.components(separatedBy: "### Errors").dropFirst().first?.components(separatedBy: "\n### ").first else {
            return [:]
        }
        var codes: [String: String] = [:]
        for row in table.split(separator: "\n") where row.hasPrefix("| `") {
            let cells = row.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 4 else { continue }
            let first = cells[1]
            for match in codeInCell.matches(in: first, range: NSRange(first.startIndex..., in: first)) {
                codes[String(first[Range(match.range(at: 1), in: first)!])] = cells[3]
            }
        }
        return codes
    }

    @Test func everyCodeIsDocumentedWithItsRetryAnswer() throws {
        let declared = try Self.declaredCodes()
        let documented = try Self.documentedCodes()
        #expect(declared.count > 50)
        for (code, retryable) in declared.sorted(by: { $0.key < $1.key }) {
            let column = try #require(documented[code], "\(code) is missing from the README's error table")
            if code != "step-failed" {
                #expect(column == (retryable ? "yes" : "no"), "\(code) is \(retryable ? "" : "not ")retryable, but the README says \(column)")
            }
        }
    }

    @Test func theTableListsNoCodeTheSourcesLack() throws {
        let declared = try Self.declaredCodes()
        for code in try Self.documentedCodes().keys.sorted() {
            #expect(declared[code] != nil, "\(code) is in the README's error table but not declared")
        }
    }
}
