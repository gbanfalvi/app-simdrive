import Foundation
import SimDriveNative

/// Reads a simulator's unified log, its launched app's output and its crash reports, each from a named cursor.
@MainActor
struct DeviceLogs {
    /// Where a cursor that has never read starts when no app was launched.
    private static let defaultLookback: TimeInterval = 60
    private static let streamAttachLimit: Duration = .seconds(5)
    /// How long a stream outlives its wait should simdrive fail to stop it.
    private static let streamBackstop: Duration = .seconds(60)
    /// Past the last entry read, so the next read starts after it.
    private static let cursorStep: TimeInterval = 0.000_001
    private static let infoPlist = "Info.plist"
    private static let executableKey = "CFBundleExecutable"
    private static let outputDirectory = "tmp"
    private static let outputFilePrefix = "simdrive"
    private static let newline = UInt8(ascii: "\n")
    private static let timeFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    private let udid: String
    private let tools: DeveloperTools
    private let store: LogStore

    init(udid: String, tools: DeveloperTools) {
        self.udid = udid
        self.tools = tools
        store = LogStore(url: StatePaths.logCursors(for: udid))
    }

    /// Removes the last launch's output, and returns where the next one's goes: the guest's own `/tmp`, since the guest
    /// resolves `simctl launch`'s paths in its filesystem, where the host's `/tmp` is out of reach.
    func prepareLaunch(dataDirectory: URL?) -> AppOutput {
        guard let directory = dataDirectory?.appendingPathComponent(Self.outputDirectory, isDirectory: true) else {
            return AppOutput(files: [:])
        }
        return AppOutput(files: Dictionary(uniqueKeysWithValues: AppOutputStream.allCases.map { stream in
            let url = directory.appendingPathComponent("\(Self.outputFilePrefix).\(stream.rawValue).txt")
            try? FileManager.default.removeItem(at: url)
            return (stream, url)
        }))
    }

    /// Makes the app the default scope, and starts every cursor at its launch.
    func recordLaunch(bundleID: String, pid: Int?, at date: Date, output: AppOutput) {
        let app = LogStore.App(bundleID: bundleID, pid: pid, launchedAt: date, stdoutPath: output.files[.stdout]?.path,
                               stderrPath: output.files[.stderr]?.path)
        store.update { $0 = LogStore.Contents(app: app) }
    }

    /// Within `run`, `--until` starts by default at the previous step's start.
    func read(_ query: LogQuery, previousStepStart: Date? = nil) async throws -> JSONValue {
        let contents = store.read()
        let target = try await target(of: query.scope)
        let digest = try LogDigest(query: query, target: target)
        let cursor = contents.cursors[query.cursor]
        let start = try start(of: query, cursor: cursor, app: contents.app, previousStepStart: previousStepStart)
        var moved = cursor ?? LogStore.Cursor(date: start)
        var result: [String: JSONValue] = ["since": .string(start.formatted(Self.timeFormat))]
        var dropped = 0
        if query.sources.contains(.log) {
            let events = if let until = query.until {
                try await events(until: try NSRegularExpression(pattern: until), query: query, target: target, since: start, digest: digest)
            } else {
                try await show(query, target: target, since: start)
            }
            let digested = digest.entries(of: events, since: start)
            result["entries"] = .array(digested.entries.map(\.json))
            dropped += digested.dropped
            if let last = events.last { moved.date = max(moved.date, last.date.addingTimeInterval(Self.cursorStep)) }
        }
        if query.sources.contains(.stdout) {
            for stream in AppOutputStream.allCases {
                let path = contents.app?.path(of: stream)
                let output = path.map { Self.newLines(of: URL(fileURLWithPath: $0), from: moved[offset: stream]) } ?? ([], 0)
                let digested = digest.lines(output.lines)
                result[stream.rawValue] = .array(digested.lines.map(JSONValue.string))
                dropped += digested.dropped
                moved[offset: stream] = output.end
            }
        }
        if query.sources.contains(.crash) {
            let checkedAt = Date.now
            let writtenAfter = query.since == nil ? cursor?.crashesCheckedAt ?? start : start
            let capturedAfter = query.since == nil ? min(contents.app?.launchedAt ?? start, start) : start
            result["crashes"] = .array(CrashReports.summaries(udid: udid, target: target, writtenAfter: writtenAfter,
                                                              capturedAfter: capturedAfter).map(\.json))
            moved.crashesCheckedAt = checkedAt
        }
        result["dropped"] = JSONValue(dropped)
        if !query.peek { store.update { [moved] in $0.cursors[query.cursor] = moved } }
        return .object(result)
    }

    /// Adds to each step's result the entries logged while it ran, and moves the default cursor past them.
    func attach(to results: [JSONValue], stepStarts: [Date]) async throws -> [JSONValue] {
        guard let first = stepStarts.first else { return results }
        let query = LogQuery()
        let target = try await target(of: query.scope)
        let digest = try LogDigest(query: query, target: target)
        let events = try await show(query, target: target, since: first)
        let ends = stepStarts.dropFirst() + [Date.distantFuture]
        let attached = zip(results, zip(stepStarts, ends)).map { result, span in
            guard case .object(var fields) = result else { return result }
            let entries = digest.entries(of: events.filter { $0.date < span.1 }, since: span.0).entries
            fields["logs"] = .array(entries.map(\.json))
            return .object(fields)
        }
        if let last = events.last {
            store.update { contents in
                var cursor = contents.cursors[query.cursor] ?? LogStore.Cursor(date: first)
                cursor.date = max(cursor.date, last.date.addingTimeInterval(Self.cursorStep))
                contents.cursors[query.cursor] = cursor
            }
        }
        return attached
    }

    private func show(_ query: LogQuery, target: LogTarget, since start: Date) async throws -> [LogEvent] {
        let result = try await tools.simctlResult(query.showArguments(udid: udid, target: target, since: start))
        guard result.succeeded else { throw SimDriveError(.logRead, "log show failed: \(result.diagnostics)") }
        return result.standardOutput.split(separator: "\n").compactMap { LogEvent(ndjson: String($0)) }.filter { $0.date >= start }
    }

    /// The events from `start` up to the first that `pattern` matches. The stream starts before the history is read, so
    /// no entry falls between them.
    private func events(until pattern: NSRegularExpression, query: LogQuery, target: LogTarget, since start: Date,
                        digest: LogDigest) async throws -> [LogEvent] {
        func matches(_ event: LogEvent) -> Bool {
            digest.includes(event) && pattern.firstMatch(in: event.message, range: NSRange(event.message.startIndex..., in: event.message)) != nil
        }
        let stream = try tools.simctlLines(query.streamArguments(udid: udid, target: target, limit: query.timeout + Self.streamBackstop))
        defer { stream.stop() }
        var lines = stream.lines.makeAsyncIterator()
        let attachWatch = Task { try await Task.sleep(for: Self.streamAttachLimit); stream.stop() }
        // `log stream` prints a header once it is attached.
        var isAttached = false
        while let line = await lines.next() {
            if LogEvent(ndjson: line) == nil {
                isAttached = true
                break
            }
        }
        attachWatch.cancel()
        guard isAttached else {
            throw SimDriveError(.logRead, "log stream did not start within \(Self.streamAttachLimit.components.seconds) s.")
        }
        var events = try await show(query, target: target, since: start)
        if let match = events.firstIndex(where: matches) { return Array(events[...match]) }
        let shownUntil = events.last?.date ?? start
        let deadline = Task { try await Task.sleep(for: query.timeout); stream.stop() }
        defer { deadline.cancel() }
        while let line = await lines.next() {
            guard let event = LogEvent(ndjson: line), event.date > shownUntil else { continue }
            events.append(event)
            if matches(event) { return events }
        }
        throw SimDriveError(.logTimeout, "No entry matched \"\(pattern.pattern)\" within \(query.timeout); \(events.count) arrived, "
                            + "which logs returns.")
    }

    private func target(of scope: LogQuery.Scope) async throws -> LogTarget {
        switch scope {
        case .all: return .all
        case .pid(let pid): return .pid(pid)
        case .process(let name): return .process(name)
        case .app(let bundleID): return .process(try await executable(of: bundleID))
        case .launchedApp:
            guard let app = store.read().app else {
                throw SimDriveError(.noLogScope, "No app was launched with simdrive; pass --app, --process, --pid or --all.")
            }
            if let process = app.process { return .process(process) }
            let process = try await executable(of: app.bundleID)
            store.update { $0.app?.process = process }
            return .process(process)
        }
    }

    private func executable(of bundleID: String) async throws -> String {
        let result = try await tools.simctlResult(["get_app_container", udid, bundleID])
        let path = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !path.isEmpty else {
            throw SimDriveError(.appNotInstalled, "\(bundleID) is not installed: \(result.diagnostics)")
        }
        let info = NSDictionary(contentsOf: URL(fileURLWithPath: path).appendingPathComponent(Self.infoPlist))
        guard let name = info?[Self.executableKey] as? String else {
            throw SimDriveError(.appNotInstalled, "\(bundleID)'s Info.plist names no executable.")
        }
        return name
    }

    private func start(of query: LogQuery, cursor: LogStore.Cursor?, app: LogStore.App?, previousStepStart: Date?) throws -> Date {
        switch query.since {
        case .launch:
            guard let app else { throw SimDriveError(.noLogScope, "No app was launched with simdrive, so --since launch has no start.") }
            return app.launchedAt
        case .date(let date):
            return date
        case .ago(let interval):
            return Date.now.addingTimeInterval(-interval)
        case nil:
            if query.until != nil, let previousStepStart { return previousStepStart }
            return cursor?.date ?? app?.launchedAt ?? Date.now.addingTimeInterval(-Self.defaultLookback)
        }
    }

    /// The complete lines past `offset`, and the offset after them. A file shorter than `offset` is read from its start.
    private static func newLines(of url: URL, from offset: UInt64) -> (lines: [String], end: UInt64) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], 0) }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = offset <= size ? offset : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: newline) else {
            return ([], start)
        }
        let complete = data[data.startIndex...lastNewline]
        return (String(decoding: complete, as: UTF8.self).split(separator: "\n").map(String.init), start + UInt64(complete.count))
    }
}
