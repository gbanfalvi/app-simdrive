import Foundation

/// Filters log events and output lines, and compacts them into the entries `logs` returns.
struct LogDigest {
    private static let ellipsis = "…"

    struct Entry: Equatable {
        /// Since the read's start.
        let milliseconds: Int
        let level: LogLevel
        /// Nil when the read is of one process, and likewise for the filtered fields.
        let process: String?
        let subsystem: String?
        let category: String?
        let message: String
        /// How many identical consecutive messages this entry stands for.
        var repeats = 1
    }

    private let minimumLevel: LogLevel
    private let grep: NSRegularExpression?
    private let width: Int
    private let limit: Int
    private let showsProcess: Bool
    private let showsSubsystem: Bool
    private let showsCategory: Bool
    private let hidesSystem: Bool

    init(query: LogQuery, target: LogTarget) throws {
        minimumLevel = query.level
        hidesSystem = !query.includesSystem && query.scope.isApp
        grep = try query.grep.map { try NSRegularExpression(pattern: $0) }
        width = query.width
        limit = query.limit
        showsProcess = target == .all
        showsSubsystem = query.subsystem == nil
        showsCategory = query.category == nil
    }

    func includes(_ event: LogEvent) -> Bool {
        event.level >= minimumLevel && (!hidesSystem || !event.isFromSystem || event.level >= .error) && matches(event.message)
    }

    /// The newest `limit` entries of `events` from `start` on, and how many were left out.
    func entries(of events: [LogEvent], since start: Date) -> (entries: [Entry], dropped: Int) {
        var entries: [Entry] = []
        var last: LogEvent?
        for event in events where event.date >= start && includes(event) {
            if let previous = last, Self.isRepeat(event, of: previous) {
                entries[entries.count - 1].repeats += 1
                continue
            }
            last = event
            entries.append(Entry(milliseconds: Int((event.date.timeIntervalSince(start) * 1000).rounded(.down)), level: event.level,
                                 process: showsProcess ? event.process : nil,
                                 subsystem: showsSubsystem && !event.subsystem.isEmpty ? event.subsystem : nil,
                                 category: showsCategory && !event.category.isEmpty ? event.category : nil,
                                 message: truncated(event.message)))
        }
        return newest(entries)
    }

    /// The newest `limit` matching lines, shortened, and how many were left out.
    func lines(_ lines: [String]) -> (lines: [String], dropped: Int) {
        newest(lines.filter(matches).map(truncated))
    }

    private func matches(_ text: String) -> Bool {
        guard let grep else { return true }
        return grep.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func truncated(_ text: String) -> String {
        guard width > 0, text.count > width else { return text }
        return text.prefix(width) + Self.ellipsis
    }

    private func newest<Element>(_ elements: [Element]) -> ([Element], Int) {
        guard limit > 0, elements.count > limit else { return (elements, 0) }
        return (Array(elements.suffix(limit)), elements.count - limit)
    }

    private static func isRepeat(_ event: LogEvent, of previous: LogEvent) -> Bool {
        event.message == previous.message && event.level == previous.level && event.process == previous.process
            && event.subsystem == previous.subsystem && event.category == previous.category
    }
}
