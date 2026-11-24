import Foundation
import SimDriveNative

/// Identifies the running executable, so a client replaces a daemon from an older build. Every build rewrites the
/// binary, changing its modification time, which is cheaper to read than a hash.
enum BuildStamp {
    static let current: String = {
        guard let path = Bundle.main.executablePath,
              let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            return "unknown"
        }
        return String(date.timeIntervalSince1970)
    }()
}

struct DaemonRequest: Codable, Sendable {
    let arguments: [String]
    let workingDirectory: String
    let build: String
    let developerDirectory: String
}

/// The JSON line a command prints: its result, or its error, the error's code, and whether retrying may help.
struct CommandResponse: Codable, Sendable {
    let ok: Bool
    let result: JSONValue?
    let error: String?
    let code: String?
    let retry: Bool?

    static func success(_ result: JSONValue) -> CommandResponse {
        CommandResponse(ok: true, result: result, error: nil, code: nil, retry: nil)
    }

    /// Errors without a code are unexpected, so whether a retry helps is unknown and `retry` is left out.
    static func failure(_ error: any Error) -> CommandResponse {
        let code = (error as? SimDriveError)?.code
        return CommandResponse(ok: false, result: nil, error: error.localizedDescription, code: code?.rawValue, retry: code?.isRetryable)
    }
}
