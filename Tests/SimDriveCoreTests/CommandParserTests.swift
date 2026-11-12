import CoreGraphics
import Foundation
import SimDriveNative
import Testing
@testable import SimDriveCore

struct CommandParserTests {
    @Test func keyWithModifiersAndRepeat() throws {
        let command = try CommandParser.parse(["key", "tab", "--mods", "cmd,shift", "--repeat", "3"])
        #expect(command == .key(name: "tab", modifiers: [.command, .shift], count: 3))
    }

    @Test func keyRejectsUnknownNamesAndModifiers() {
        expectUsageError { try CommandParser.parse(["key", "nope"]) }
        expectUsageError { try CommandParser.parse(["key", "a", "--mods", "hyper"]) }
        expectUsageError { try CommandParser.parse(["key", "a", "--repeat", "0"]) }
    }

    @Test func pointsWithADecimalPointInZeroToOneAreFractions() throws {
        #expect(try CommandParser.parse(["tap", "0.5", "1"]) == .tap(.normalized(CGPoint(x: 0.5, y: 1)), display: .automatic))
        #expect(try CommandParser.parse(["tap", "1", "1"]) == .tap(.pixels(CGPoint(x: 1, y: 1)), display: .automatic))
        #expect(try CommandParser.parse(["tap", "120", "0.5"]) == .tap(.pixels(CGPoint(x: 120, y: 0.5)), display: .automatic))
        expectUsageError { try CommandParser.parse(["tap", "-1", "2"]) }
    }

    @Test func swipeDefaultsAndOptions() throws {
        let plain = try CommandParser.parse(["swipe", "0.5", "0.9", "0.5", "0.1"])
        #expect(plain == .swipe(from: .normalized(CGPoint(x: 0.5, y: 0.9)), to: .normalized(CGPoint(x: 0.5, y: 0.1)),
                                duration: CommandParser.defaultSwipeDuration, edge: nil, display: .automatic))
        let edge = try CommandParser.parse(["swipe", "0.5", "0.99", "0.5", "0.5", "--edge", "bottom", "--duration", "250", "--display", "cover"])
        #expect(edge == .swipe(from: .normalized(CGPoint(x: 0.5, y: 0.99)), to: .normalized(CGPoint(x: 0.5, y: 0.5)),
                               duration: .milliseconds(250), edge: .bottom, display: .cover))
    }

    @Test func postureAndOrientationReadWithoutAnArgument() throws {
        #expect(try CommandParser.parse(["posture"]) == .posture(nil))
        #expect(try CommandParser.parse(["posture", "half"]) == .posture(.partiallyOpen))
        #expect(try CommandParser.parse(["orientation"]) == .orientation(nil))
        #expect(try CommandParser.parse(["orientation", "upside-down"]) == .orientation(.portraitUpsideDown))
    }

    @Test func buttonDefaultsAndOptions() throws {
        #expect(try CommandParser.parse(["button", "home"]) == .button(.home, count: 1, hold: CommandParser.defaultButtonHold))
        #expect(try CommandParser.parse(["button", "play-pause", "--repeat", "2", "--hold", "800"])
            == .button(.playPause, count: 2, hold: .milliseconds(800)))
        expectUsageError { try CommandParser.parse(["button", "select", "--hold", "0"]) }
        expectUsageError { try CommandParser.parse(["button", "power"]) }
    }

    @Test func pasteboardReadsWithoutAnArgument() throws {
        #expect(try CommandParser.parse(["pasteboard"]) == .pasteboard(text: nil))
        #expect(try CommandParser.parse(["pasteboard", "héllo wörld"]) == .pasteboard(text: "héllo wörld"))
        #expect(try CommandParser.parse(["pasteboard", ""]) == .pasteboard(text: ""))
        expectUsageError { try CommandParser.parse(["pasteboard", "a", "b"]) }
    }

    @Test func screenshotDefaultsToTheMaximumDimension() throws {
        #expect(try CommandParser.parse(["screenshot", "a.png"])
            == .screenshot(path: "a.png", display: .automatic, maxDimension: CommandParser.defaultMaxDimension))
        #expect(try CommandParser.parse(["screenshot", "a.png", "--max-dim", "0", "--display", "3"])
            == .screenshot(path: "a.png", display: .index(3), maxDimension: 0))
    }

    @Test func treeReadsTheWholeHierarchyOrOnePoint() throws {
        #expect(try CommandParser.parse(["tree"]) == .tree(at: nil, detail: .light))
        #expect(try CommandParser.parse(["tree", "--full"]) == .tree(at: nil, detail: .full))
        #expect(try CommandParser.parse(["tree", "0.5", "0.25"]) == .tree(at: .normalized(CGPoint(x: 0.5, y: 0.25)), detail: .light))
        #expect(try CommandParser.parse(["tree", "600", "400", "--full"]) == .tree(at: .pixels(CGPoint(x: 600, y: 400)), detail: .full))
        expectUsageError { try CommandParser.parse(["tree", "0.5"]) }
        expectUsageError { try CommandParser.parse(["tree", "--flat"]) }
        #expect(try CommandParser.parse(["tree"]).isStep)
    }

    @Test func settingListsReadsOrChanges() throws {
        #expect(try CommandParser.parse(["setting"]) == .setting(nil, value: nil))
        #expect(try CommandParser.parse(["setting", "appearance"]) == .setting(SettingCatalog.appearance, value: nil))
        #expect(try CommandParser.parse(["setting", "appearance", "dark"]) == .setting(SettingCatalog.appearance, value: "dark"))
        #expect(try CommandParser.parse(["setting", "glass-tint", "1"]) == .setting(SettingCatalog.setting(named: "glass-tint"), value: 1))
        expectUsageError { try CommandParser.parse(["setting", "voiceover", "on"]) }
        expectUsageError { try CommandParser.parse(["setting", "bold-text", "maybe"]) }
        expectUsageError { try CommandParser.parse(["setting", "bold-text", "on", "now"]) }
    }

    @Test func launchPassesArgumentsAfterTheBundleIdentifier() throws {
        #expect(try CommandParser.parse(["launch", "com.example", "--", "--flag", "x"])
            == .launch(bundleID: "com.example", arguments: ["--flag", "x"]))
    }

    @Test func unknownCommandsAndOptionsFail() {
        expectUsageError { try CommandParser.parse([]) }
        expectUsageError { try CommandParser.parse(["fly"]) }
        expectUsageError { try CommandParser.parse(["tap", "1", "1", "--force"]) }
        expectUsageError { try CommandParser.parse(["doctor", "now"]) }
    }

    @Test func runReadsInlineSteps() throws {
        let command = try CommandParser.parse(["run", "--json", #"["tap 0.5 0.5", ["key", "tab"], ["wait", 100]]"#])
        #expect(command == .run(steps: [
            Step(arguments: ["tap", "0.5", "0.5"], command: .tap(.normalized(CGPoint(x: 0.5, y: 0.5)), display: .automatic)),
            Step(arguments: ["key", "tab"], command: .key(name: "tab", modifiers: [], count: 1)),
            Step(arguments: ["wait", "100"], command: .wait(milliseconds: 100)),
        ], attachesLogs: false))
        #expect(!command.isStep)
        #expect(try CommandParser.parse(["run", "--logs", "--json", #"["wait 1"]"#])
            == .run(steps: [Step(arguments: ["wait", "1"], command: .wait(milliseconds: 1))], attachesLogs: true))
    }

    @Test func logsDefaultsToTheLaunchedAppSinceTheCursor() throws {
        #expect(try CommandParser.parse(["logs"]) == .logs(LogQuery()))
        #expect(try CommandParser.parse(["logs"]).isStep)
    }

    @Test func logsReadsEveryOption() throws {
        let command = try CommandParser.parse([
            "logs", "--app", "com.example", "--subsystem", "net", "--category", "http", "--level", "error", "--grep", "fail(ed)?",
            "--predicate", "eventMessage CONTAINS \"x\"", "--source", "log,crash", "--since", "30s", "--cursor", "watcher", "--peek",
            "--until", "done", "--timeout", "800", "--limit", "0", "--width", "80", "--system",
        ])
        var expected = LogQuery()
        expected.scope = .app(bundleID: "com.example")
        expected.subsystem = "net"
        expected.category = "http"
        expected.level = .error
        expected.grep = "fail(ed)?"
        expected.predicate = "eventMessage CONTAINS \"x\""
        expected.includesSystem = true
        expected.sources = [.log, .crash]
        expected.since = .ago(30)
        expected.cursor = "watcher"
        expected.peek = true
        expected.until = "done"
        expected.timeout = .milliseconds(800)
        expected.limit = 0
        expected.width = 80
        #expect(command == .logs(expected))
    }

    @Test func logsScopesAndStarts() throws {
        #expect(try CommandParser.parse(["logs", "--all"]) == .logs(LogQuery(scope: .all)))
        #expect(try CommandParser.parse(["logs", "--pid", "42"]) == .logs(LogQuery(scope: .pid(42))))
        #expect(try CommandParser.parse(["logs", "--process", "SpringBoard"]) == .logs(LogQuery(scope: .process("SpringBoard"))))
        #expect(try CommandParser.parse(["logs", "--since", "launch"]) == .logs(LogQuery(since: .launch)))
        #expect(try CommandParser.parse(["logs", "--since", "2m"]) == .logs(LogQuery(since: .ago(120))))
        #expect(try CommandParser.parse(["logs", "--since", "2026-11-12T15:18:01Z"])
            == .logs(LogQuery(since: .date(Date(timeIntervalSince1970: 1_794_496_681)))))
    }

    @Test func logsRejectsConflictsAndBadValues() {
        expectUsageError { try CommandParser.parse(["logs", "--all", "--app", "com.example"]) }
        expectUsageError { try CommandParser.parse(["logs", "--level", "verbose"]) }
        expectUsageError { try CommandParser.parse(["logs", "--grep", "("]) }
        expectUsageError { try CommandParser.parse(["logs", "--source", "syslog"]) }
        expectUsageError { try CommandParser.parse(["logs", "--since", "yesterday"]) }
        expectUsageError { try CommandParser.parse(["logs", "--until", "x", "--source", "stdout"]) }
        expectUsageError { try CommandParser.parse(["logs", "--timeout", "100"]) }
        expectUsageError { try CommandParser.parse(["logs", "--limit", "-1"]) }
        expectUsageError { try CommandParser.parse(["logs", "now"]) }
    }

    @Test func runChecksEveryStepBeforeRunning() {
        expectError(.stepInvalid) { try CommandParser.parse(["run", "--json", #"["key tab", "bogus"]"#]) }
        expectError(.stepInvalid) { try CommandParser.parse(["run", "--json", #"["stop"]"#]) }
        expectError(.stepInvalid) { try CommandParser.parse(["run", "--json", #"[["run", "--json", "[]"]]"#]) }
    }

    @Test func usageErrorsPointToTheHelp() {
        #expect(SimDriveError.usage("Missing command").message == "Missing command. Run `simdrive help` for usage.")
    }

    @Test func orientationNamesMatchTheirOutput() {
        for orientation in DeviceOrientation.allCases {
            #expect(DeviceOrientation(name: orientation.name) == orientation)
        }
        #expect(DeviceOrientation(name: "landscape-left") == .landscapeLeft)
        #expect(DeviceOrientation(name: "portraitUpsideDown") == .portraitUpsideDown)
        #expect(DeviceOrientation(name: "sideways") == nil)
    }
}
