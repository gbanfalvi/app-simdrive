import Foundation
import Testing
@testable import SimDriveCore

struct LogQueryTests {
    private let udid = "UDID"
    private let since = Date(timeIntervalSince1970: 1_794_496_681.75)

    @Test func predicateCombinesTheTargetAndFilters() {
        var query = LogQuery(subsystem: "com.example", category: "net")
        query.predicate = "eventMessage CONTAINS \"x\""
        #expect(query.predicate(for: .process("My App"))
            == #"process == "My App" AND subsystem == "com.example" AND category == "net" AND (eventMessage CONTAINS "x")"#)
        #expect(LogQuery().predicate(for: .pid(42)) == "processID == 42")
        #expect(LogQuery().predicate(for: .all) == nil)
    }

    @Test func predicateEscapesQuotesAndBackslashes() {
        #expect(LogQuery().predicate(for: .process(#"a"b\c"#)) == #"process == "a\"b\\c""#)
    }

    @Test func showStartsAtTheWholeSecondAndIncludesLowerLevels() {
        #expect(LogQuery().showArguments(udid: udid, target: .all, since: since)
            == ["spawn", udid, "log", "show", "--style", "ndjson", "--start", "@1794496681"])
        #expect(LogQuery(level: .info).showArguments(udid: udid, target: .pid(7), since: since)
            == ["spawn", udid, "log", "show", "--style", "ndjson", "--start", "@1794496681", "--info", "--predicate", "processID == 7"])
        #expect(LogQuery(level: .debug).showArguments(udid: udid, target: .all, since: since).suffix(2) == ["--info", "--debug"])
    }

    @Test func streamTakesTheLevelAndABackstop() {
        #expect(LogQuery(level: .error).streamArguments(udid: udid, target: .process("App"), limit: .seconds(65))
            == ["spawn", udid, "log", "stream", "--style", "ndjson", "--type", "log", "--level", "default", "--timeout", "66",
                "--predicate", #"process == "App""#])
        #expect(LogQuery(level: .debug).streamArguments(udid: udid, target: .all, limit: .seconds(1)).contains("debug"))
    }
}
