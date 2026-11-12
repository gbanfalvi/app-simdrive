import Foundation

/// A unified log level, lowest first.
enum LogLevel: Int, CaseIterable, Comparable, Sendable {
    case debug, info, `default`, error, fault

    var name: String {
        switch self {
        case .debug: "debug"
        case .info: "info"
        case .default: "default"
        case .error: "error"
        case .fault: "fault"
        }
    }

    init?(name: String) {
        guard let level = Self.allCases.first(where: { $0.name == name.lowercased() }) else { return nil }
        self = level
    }

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whose log entries a query reads, once an app is resolved to its executable.
enum LogTarget: Equatable, Sendable {
    case process(String)
    case pid(Int)
    case all
}

/// What `logs` reads: whose entries, which ones, from when, how many, and whether to wait for one.
struct LogQuery: Equatable, Sendable {
    enum Scope: Equatable, Sendable {
        /// The app `launch` last started.
        case launchedApp
        case app(bundleID: String)
        case process(String)
        case pid(Int)
        case all

        var isApp: Bool {
            switch self {
            case .launchedApp, .app: true
            case .process, .pid, .all: false
            }
        }
    }

    enum Source: String, CaseIterable, Sendable {
        case log, stdout, crash
    }

    enum Start: Equatable, Sendable {
        case launch
        case date(Date)
        case ago(TimeInterval)
    }

    static let defaultCursor = "default"
    static let defaultTimeout: Duration = .milliseconds(5000)
    static let defaultLimit = 50
    static let defaultWidth = 240

    var scope = Scope.launchedApp
    var subsystem: String?
    var category: String?
    var level = LogLevel.default
    /// A regular expression that messages and output lines must match.
    var grep: String?
    /// A raw NSPredicate, combined with the other filters.
    var predicate: String?
    /// Keeps what system libraries log in an app below error level, which an app's read otherwise leaves out.
    var includesSystem = false
    var sources = Set(Source.allCases)
    var since: Start?
    var cursor = defaultCursor
    /// Reads without moving the cursor.
    var peek = false
    /// A regular expression to wait for.
    var until: String?
    var timeout = defaultTimeout
    /// 0 keeps every entry.
    var limit = defaultLimit
    /// 0 keeps whole messages.
    var width = defaultWidth

    func showArguments(udid: String, target: LogTarget, since: Date) -> [String] {
        // `log` takes whole seconds; entries before `since` are dropped after reading.
        var arguments = ["spawn", udid, "log", "show", "--style", "ndjson", "--start", "@\(Int(since.timeIntervalSince1970.rounded(.down)))"]
        if level <= .info { arguments.append("--info") }
        if level == .debug { arguments.append("--debug") }
        if let predicate = predicate(for: target) { arguments += ["--predicate", predicate] }
        return arguments
    }

    /// `limit` ends the stream should simdrive fail to interrupt it.
    func streamArguments(udid: String, target: LogTarget, limit: Duration) -> [String] {
        var arguments = ["spawn", udid, "log", "stream", "--style", "ndjson", "--type", "log", "--level", min(level, .default).name,
                         "--timeout", String(limit.components.seconds + 1)]
        if let predicate = predicate(for: target) { arguments += ["--predicate", predicate] }
        return arguments
    }

    func predicate(for target: LogTarget) -> String? {
        var clauses: [String] = []
        switch target {
        case .process(let name): clauses.append("process == \(Self.quoted(name))")
        case .pid(let pid): clauses.append("processID == \(pid)")
        case .all: break
        }
        if let subsystem { clauses.append("subsystem == \(Self.quoted(subsystem))") }
        if let category { clauses.append("category == \(Self.quoted(category))") }
        if let predicate { clauses.append("(\(predicate))") }
        return clauses.isEmpty ? nil : clauses.joined(separator: " AND ")
    }

    private static func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
