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

/// The JSON line a command prints: its result, or its error and the error's code.
struct CommandResponse: Codable, Sendable {
    let ok: Bool
    let result: JSONValue?
    let error: String?
    let code: String?

    static func success(_ result: JSONValue) -> CommandResponse {
        CommandResponse(ok: true, result: result, error: nil, code: nil)
    }

    static func failure(_ error: any Error) -> CommandResponse {
        CommandResponse(ok: false, result: nil, error: error.localizedDescription, code: (error as? SimDriveError)?.code.rawValue)
    }
}
