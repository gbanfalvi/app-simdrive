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
    /// Nil for a crash known only from the guest's log, as a repeat ReportCrash wrote no report for (F32).
    let path: String?
}

/// An app's process ending on a signal, as SpringBoard logs it whether or not a crash report is written.
struct AppExit: Equatable, Sendable {
    let bundleID: String
    let pid: Int
    let signal: String
    let date: Date
}

/// A crash report file on the Mac, and when it was last written.
struct CrashReportFile: Sendable {
    let url: URL
    let modified: Date
}

/// Reads crash reports: a simulator's from the Mac's DiagnosticReports, which name the simulator in their coalition, and
/// a physical device's from the copies `DeviceCrashReports` makes.
enum CrashReports {
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    static let reportExtension = "ips"
    private static let deviceCoalitionPrefix = "com.apple.CoreSimulator.SimDevice."
    private static let frameLimit = 10

    /// The Mac's crash reports, every simulator's among them.
    static func simulatorReports() -> [CrashReportFile] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return files.compactMap { file in
            guard file.pathExtension == reportExtension, let modified = try? file.resourceValues(forKeys: keys).contentModificationDate else {
                return nil
            }
            return CrashReportFile(url: file, modified: modified)
        }
    }

    /// The reports among `files` of `target`'s processes written after `writtenAfter` of crashes after `capturedAfter`,
    /// oldest first; `udid` keeps a simulator's own. The system rewrites old reports, so the write date alone would repeat
    /// them.
    static func summaries(of files: [CrashReportFile], udid: String?, target: LogTarget, writtenAfter: Date,
                          capturedAfter: Date) -> [CrashSummary] {
        files.filter { $0.modified > writtenAfter }.compactMap { file in
            (try? String(contentsOf: file.url, encoding: .utf8)).flatMap { summary(ofReport: $0, path: file.url.path, udid: udid) }
        }.filter { summary in
            guard capturedAt(summary).map({ $0 >= capturedAfter }) ?? true else { return false }
            return switch target {
            case .process(let name): summary.process == name
            case .pid(let pid): summary.pid == pid
            case .all: true
            }
        }.sorted { $0.time < $1.time }
    }

    /// Nil when the report is not a crash, or with `udid`, of another simulator. A device's reports are all its own.
    static func summary(ofReport text: String, path: String, udid: String?) -> CrashSummary? {
        guard let headerEnd = text.firstIndex(of: "\n"),
              let body = try? JSONSerialization.jsonObject(with: Data(text[text.index(after: headerEnd)...].utf8)) as? [String: Any],
              udid.map({ body["coalitionName"] as? String == deviceCoalitionPrefix + $0 }) ?? true,
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

    // MARK: From the guest's log

    /// SpringBoard's FrontBoard lines for every process that exits, such as
    /// `[app<com.example>:95205] Process exited: <RBSProcessExitContext| … domain:signal(2) code:SIGTRAP(5)>>.`
    /// (iOS 27.2). A crash ends on a signal; a relaunch or a quit ends in the runningboard domain.
    static let exitPredicate = "subsystem == \"com.apple.FrontBoard\" AND category == \"Process\" AND eventMessage CONTAINS \"Process exited\""
    /// Signals the system sends to end a process, rather than a crash.
    private static let terminationSignals: Set<String> = ["SIGKILL", "SIGTERM"]
    static func appExit(_ event: LogEvent) -> AppExit? {
        let exitPattern = /^\[app<([^>]+)>:(\d+)\] Process exited: .*domain:signal\(\d+\) code:([A-Z0-9]+)\(\d+\)/
        guard event.subsystem == "com.apple.FrontBoard", event.category == "Process",
              let match = event.message.firstMatch(of: exitPattern), let pid = Int(match.2),
              !terminationSignals.contains(String(match.3)) else { return nil }
        return AppExit(bundleID: String(match.1), pid: pid, signal: String(match.3), date: event.date)
    }

    /// The crashes `exits` show that no report in `reported` covers, one per pid, named `process`.
    static func summaries(of exits: [AppExit], process: (AppExit) -> String, reported: [CrashSummary]) -> [CrashSummary] {
        let reportedPids = Set(reported.compactMap(\.pid))
        var seen = Set<Int>()
        return exits.filter { !reportedPids.contains($0.pid) && seen.insert($0.pid).inserted }.map { exit in
            CrashSummary(process: process(exit), pid: exit.pid, time: exit.date.formatted(captureTimeFormat), exception: exit.signal,
                         reason: nil, frames: [], path: nil)
        }
    }

    /// As reports write `captureTime`.
    private static let captureTimeFormat = Date.VerbatimFormatStyle(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits).\(secondFraction: .fractional(4)) +0000",
        timeZone: .gmt, calendar: Calendar(identifier: .gregorian))

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
