import Foundation

/// A crash report's gist: what crashed, why, and where.
struct CrashSummary: Equatable, Sendable {
    let process: String
    let pid: Int?
    let time: String
    let exception: String
    /// The report's application-specific information, such as a Swift fatal error's message.
    let reason: String?
    /// The crashing thread's top frames, or the uncaught exception's.
    let frames: [String]
    let path: String
}

/// Reads the crash reports of a simulator's processes.
enum CrashReports {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    private static let reportExtension = "ips"
    private static let deviceCoalitionPrefix = "com.apple.CoreSimulator.SimDevice."
    private static let frameLimit = 10

    /// The device's reports of `target`'s processes written after `writtenAfter` of crashes after `capturedAfter`, oldest
    /// first. The system rewrites old reports, so the write date alone would repeat them.
    static func summaries(udid: String, target: LogTarget, writtenAfter: Date, capturedAfter: Date) -> [CrashSummary] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return files.filter { file in
            guard file.pathExtension == reportExtension,
                  let modified = try? file.resourceValues(forKeys: keys).contentModificationDate else { return false }
            return modified > writtenAfter
        }.compactMap { file in
            (try? String(contentsOf: file, encoding: .utf8)).flatMap { summary(ofReport: $0, path: file.path, udid: udid) }
        }.filter { summary in
            guard capturedAt(summary).map({ $0 >= capturedAfter }) ?? true else { return false }
            return switch target {
            case .process(let name): summary.process == name
            case .pid(let pid): summary.pid == pid
            case .all: true
            }
        }.sorted { $0.time < $1.time }
    }

    /// Nil when the report is of another device or not a crash.
    static func summary(ofReport text: String, path: String, udid: String) -> CrashSummary? {
        guard let headerEnd = text.firstIndex(of: "\n"),
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: headerEnd)...].utf8)) as? [String: Any],
              body["coalitionName"] as? String == deviceCoalitionPrefix + udid,
              let process = body["procName"] as? String, let exception = body["exception"] as? [String: Any] else {
            return nil
        }
        let images = (body["usedImages"] as? [[String: Any]])?.map { $0["name"] as? String } ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faultingThread = body["faultingThread"] as? Int
        let frames = body["lastExceptionBacktrace"] as? [[String: Any]]
            ?? faultingThread.flatMap { threads.indices.contains($0) ? threads[$0]["frames"] as? [[String: Any]] : nil } ?? []
        let reasons = (body["asi"] as? [String: [String]])?.sorted { $0.key < $1.key }.flatMap(\.value) ?? []
        return CrashSummary(process: process, pid: body["pid"] as? Int, time: body["captureTime"] as? String ?? "",
                            exception: description(of: exception), reason: reasons.isEmpty ? nil : reasons.joined(separator: " "),
                            frames: frames.prefix(frameLimit).map { describe($0, images: images) }, path: path)
    }

    /// From a capture time such as `2026-11-12 13:54:50.9488 +0000`, the unified log's format but for a space.
    static func capturedAt(_ summary: CrashSummary) -> Date? {
        guard let zoneSpace = summary.time.lastIndex(of: " ") else { return nil }
        var timestamp = summary.time
        timestamp.remove(at: zoneSpace)
        return LogEvent.date(fromTimestamp: timestamp)
    }

    private static func description(of exception: [String: Any]) -> String {
        let type = exception["type"] as? String ?? "unknown"
        guard let signal = exception["signal"] as? String else { return type }
        return "\(type) (\(signal))"
    }

    private static func describe(_ frame: [String: Any], images: [String?]) -> String {
        let image = (frame["imageIndex"] as? Int).flatMap { images.indices.contains($0) ? images[$0] : nil } ?? "???"
        if let symbol = frame["symbol"] as? String {
            return "\(image) \(symbol) + \(frame["symbolLocation"] as? Int ?? 0)"
        }
        return "\(image) + \(frame["imageOffset"] as? Int ?? 0)"
    }
}
