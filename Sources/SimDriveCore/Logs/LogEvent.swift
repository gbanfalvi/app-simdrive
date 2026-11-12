import Foundation

/// One unified log message, decoded from `log --style ndjson`.
struct LogEvent: Equatable, Sendable {
    private static let logEventType = "logEvent"
    private static let systemImagePrefixes = ["/System/", "/usr/"]
    private static let runtimeRoot = "/RuntimeRoot/"
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    let date: Date
    let level: LogLevel
    let message: String
    let subsystem: String
    let category: String
    let process: String
    let pid: Int
    /// Whether a system library logged it, rather than the app's own code or the frameworks it embeds.
    let isFromSystem: Bool

    init(date: Date, level: LogLevel, message: String, subsystem: String = "", category: String = "", process: String, pid: Int,
         isFromSystem: Bool = false) {
        self.date = date
        self.level = level
        self.message = message
        self.subsystem = subsystem
        self.category = category
        self.process = process
        self.pid = pid
        self.isFromSystem = isFromSystem
    }

    /// Nil for `log`'s headers and for events other than messages.
    init?(ndjson line: String) {
        guard line.hasPrefix("{"), let raw = try? JSONDecoder().decode(Raw.self, from: Data(line.utf8)),
              raw.eventType == Self.logEventType, let date = Self.date(fromTimestamp: raw.timestamp),
              let level = LogLevel(name: raw.messageType) else {
            return nil
        }
        self.init(date: date, level: level, message: raw.eventMessage, subsystem: raw.subsystem ?? "", category: raw.category ?? "",
                  process: (raw.processImagePath as NSString).lastPathComponent, pid: raw.processID,
                  isFromSystem: raw.senderImagePath.map(Self.isSystemImage) ?? false)
    }

    /// The host's and the runtime's libraries, which a simulator's processes load from `/System`, `/usr` or the runtime root.
    static func isSystemImage(_ path: String) -> Bool {
        systemImagePrefixes.contains { path.hasPrefix($0) } || path.contains(runtimeRoot)
    }

    /// Parses `2026-11-12 16:05:29.405902+0000`, keeping the microseconds that date formatters drop.
    static func date(fromTimestamp timestamp: String) -> Date? {
        let halves = timestamp.split(separator: " ")
        guard halves.count == 2, halves[1].count > 5 else { return nil }
        let day = halves[0].split(separator: "-").compactMap { Int($0) }
        let zone = halves[1].suffix(5)
        let clock = halves[1].dropLast(5).split(separator: ":")
        guard day.count == 3, clock.count == 3, let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Double(clock[2]),
              let sign = zone.first, sign == "+" || sign == "-", let zoneHours = Int(zone.dropFirst().prefix(2)),
              let zoneMinutes = Int(zone.suffix(2)),
              let start = calendar.date(from: DateComponents(year: day[0], month: day[1], day: day[2], hour: hour, minute: minute)) else {
            return nil
        }
        let offset = TimeInterval((zoneHours * 60 + zoneMinutes) * 60) * (sign == "-" ? -1 : 1)
        return start.addingTimeInterval(second - offset)
    }

    private struct Raw: Decodable {
        let timestamp: String
        let messageType: String
        let eventType: String
        let eventMessage: String
        let subsystem: String?
        let category: String?
        let processImagePath: String
        let processID: Int
        let senderImagePath: String?
    }
}
