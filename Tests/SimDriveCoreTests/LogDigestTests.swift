import Foundation
import Testing
@testable import SimDriveCore

struct LogDigestTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func event(_ offset: TimeInterval, _ message: String, level: LogLevel = .default, subsystem: String = "com.example",
                       process: String = "App") -> LogEvent {
        LogEvent(date: start.addingTimeInterval(offset), level: level, message: message, subsystem: subsystem, category: "net",
                 process: process, pid: 1)
    }

    private func digest(_ query: LogQuery = LogQuery(), target: LogTarget = .process("App")) throws -> LogDigest {
        try LogDigest(query: query, target: target)
    }

    @Test func decodesNDJSONKeepingMicroseconds() throws {
        let line = #"{"timestamp":"2026-11-12 16:05:29.405902+0100","messageType":"Error","eventType":"logEvent","#
            + #""eventMessage":"boom","subsystem":"com.example","category":"","processImagePath":"\/a\/b\/App","processID":7}"#
        let event = try #require(LogEvent(ndjson: line))
        #expect(event.level == .error)
        #expect(event.process == "App")
        #expect(event.pid == 7)
        #expect(abs(event.date.timeIntervalSince1970 - 1_794_495_929.405902) < 0.000_001)
    }

    @Test func skipsHeadersAndOtherEvents() {
        #expect(LogEvent(ndjson: #"Filtering the log data using "process == "App"""#) == nil)
        let activity = #"{"timestamp":"2026-11-12 16:05:29.405902+0000","messageType":"Default","eventType":"activityCreateEvent","#
            + #""eventMessage":"","processImagePath":"\/App","processID":7}"#
        #expect(LogEvent(ndjson: activity) == nil)
    }

    @Test func entriesAreRelativeAndLeaveOutFilteredFields() throws {
        let entries = try digest().entries(of: [event(-1, "before"), event(0.0425, "hello")], since: start).entries
        #expect(entries == [LogDigest.Entry(milliseconds: 42, level: .default, process: nil, subsystem: "com.example", category: "net",
                                            message: "hello")])
        let filtered = try digest(LogQuery(subsystem: "com.example"), target: .all).entries(of: [event(0, "hi")], since: start).entries
        #expect(filtered.first?.subsystem == nil)
        #expect(filtered.first?.process == "App")
    }

    @Test func mergesConsecutiveRepeats() throws {
        let events = [event(0, "tick"), event(1, "tick"), event(2, "tock"), event(3, "tick")]
        let entries = try digest().entries(of: events, since: start).entries
        #expect(entries.map(\.message) == ["tick", "tock", "tick"])
        #expect(entries.map(\.repeats) == [2, 1, 1])
    }

    @Test func filtersByLevelAndPattern() throws {
        let events = [event(0, "fine"), event(1, "request failed", level: .error), event(2, "retry failed", level: .info)]
        #expect(try digest(LogQuery(level: .error)).entries(of: events, since: start).entries.map(\.message) == ["request failed"])
        #expect(try digest(LogQuery(level: .debug, grep: "fail")).entries(of: events, since: start).entries.map(\.message)
            == ["request failed", "retry failed"])
    }

    @Test func anAppsReadLeavesOutSystemLibrariesBelowError() throws {
        let system = { (message: String, level: LogLevel) in
            LogEvent(date: self.start, level: level, message: message, process: "App", pid: 1, isFromSystem: true)
        }
        let events = [event(0, "mine"), system("UIKit chatter", .default), system("constraint broken", .error)]
        #expect(try digest().entries(of: events, since: start).entries.map(\.message) == ["mine", "constraint broken"])
        #expect(try digest(LogQuery(includesSystem: true)).entries(of: events, since: start).entries.count == 3)
        #expect(try digest(LogQuery(scope: .process("App"))).entries(of: events, since: start).entries.count == 3)
    }

    @Test func systemImagesAreTheHostsAndTheRuntimes() {
        #expect(LogEvent.isSystemImage("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore"))
        #expect(LogEvent.isSystemImage("/usr/lib/system/libxpc.dylib"))
        #expect(LogEvent.isSystemImage("/Library/Developer/CoreSimulator/Volumes/iOS/RuntimeRoot/usr/lib/libobjc.A.dylib"))
        #expect(!LogEvent.isSystemImage("/Users/me/Library/Developer/CoreSimulator/Devices/X/data/Containers/Bundle/Application/Y/App.app/App"))
    }

    @Test func keepsTheNewestAndCountsTheRest() throws {
        let events = (0..<5).map { event(TimeInterval($0), "line \($0)") }
        let digested = try digest(LogQuery(limit: 2)).entries(of: events, since: start)
        #expect(digested.entries.map(\.message) == ["line 3", "line 4"])
        #expect(digested.dropped == 3)
        #expect(try digest(LogQuery(limit: 0)).entries(of: events, since: start).dropped == 0)
    }

    @Test func shortensLongMessagesAndLines() throws {
        let narrow = try digest(LogQuery(width: 4))
        #expect(narrow.entries(of: [event(0, "abcdefg")], since: start).entries.first?.message == "abcd…")
        #expect(narrow.lines(["abc", "abcdefg"]).lines == ["abc", "abcd…"])
        #expect(try digest(LogQuery(width: 0)).lines(["abcdefg"]).lines == ["abcdefg"])
    }

    @Test func linesFollowTheGrepAndLimit() throws {
        let digested = try digest(LogQuery(grep: "^ok", limit: 1)).lines(["ok 1", "no", "ok 2"])
        #expect(digested.lines == ["ok 2"])
        #expect(digested.dropped == 1)
    }

    @Test func entryJSONOmitsDefaults() {
        let plain = LogDigest.Entry(milliseconds: 5, level: .default, process: nil, subsystem: nil, category: nil, message: "m")
        #expect(plain.json == ["ms": 5, "message": "m"])
        var detailed = LogDigest.Entry(milliseconds: 5, level: .fault, process: "App", subsystem: "s", category: "c", message: "m")
        detailed.repeats = 3
        #expect(detailed.json == ["ms": 5, "message": "m", "level": "fault", "process": "App", "subsystem": "s", "category": "c", "repeats": 3])
    }
}
