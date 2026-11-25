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

    @Test func tapTakesALabelOrAnIdentifierInsteadOfAPoint() throws {
        #expect(try CommandParser.parse(["tap", "--label", "View"])
            == .tapElement(.label("View"), timeout: CommandParser.defaultElementTimeout))
        #expect(try CommandParser.parse(["tap", "--id", "play-button", "--timeout", "0"])
            == .tapElement(.identifier("play-button"), timeout: .zero))
        expectUsageError { try CommandParser.parse(["tap", "--label", "View", "--id", "view"]) }
        expectUsageError { try CommandParser.parse(["tap", "--label", "View", "0.5", "0.5"]) }
        expectUsageError { try CommandParser.parse(["tap", "--label", "View", "--display", "inner"]) }
        expectUsageError { try CommandParser.parse(["tap", "--label", ""]) }
        expectUsageError { try CommandParser.parse(["tap", "0.5", "0.5", "--timeout", "100"]) }
    }

    @Test func swipeCanRepeatUntilAnElementIsShown() throws {
        let path: [ScreenPoint] = [.normalized(CGPoint(x: 0.5, y: 0.8)), .normalized(CGPoint(x: 0.5, y: 0.3))]
        #expect(try CommandParser.parse(["swipe", "0.5", "0.8", "0.5", "0.3", "--until-label", "Row 30"])
            == .swipeUntil(path: path, duration: CommandParser.defaultSwipeDuration, selector: .label("Row 30"),
                           maxSwipes: CommandParser.defaultMaxSwipes))
        #expect(try CommandParser.parse(["swipe", "0.5", "0.8", "0.5", "0.3", "--until-id", "row-30", "--max-swipes", "3"])
            == .swipeUntil(path: path, duration: CommandParser.defaultSwipeDuration, selector: .identifier("row-30"), maxSwipes: 3))
        expectUsageError { try CommandParser.parse(["swipe", "0.5", "0.8", "0.5", "0.3", "--until-label", "Row", "--edge", "bottom"]) }
        expectUsageError { try CommandParser.parse(["swipe", "0.5", "0.8", "0.5", "0.3", "--max-swipes", "3"]) }
        expectUsageError { try CommandParser.parse(["swipe", "0.5", "0.8", "0.5", "0.3", "--until-label", "Row", "--max-swipes", "0"]) }
    }

    @Test func waitTakesMillisecondsOrAnElement() throws {
        #expect(try CommandParser.parse(["wait", "--label", "Done"])
            == .waitForElement(.label("Done"), gone: false, timeout: CommandParser.defaultElementTimeout))
        #expect(try CommandParser.parse(["wait", "--id", "spinner", "--absent", "--timeout", "10000"])
            == .waitForElement(.identifier("spinner"), gone: true, timeout: .milliseconds(10000)))
        expectUsageError { try CommandParser.parse(["wait", "100", "--absent"]) }
        expectUsageError { try CommandParser.parse(["wait", "--label", "Done", "--timeout", "-1"]) }
    }

    @Test func pinchAndRotateTakeACenterAndAnAmount() throws {
        let center = ScreenPoint.normalized(CGPoint(x: 0.5, y: 0.5))
        #expect(try CommandParser.parse(["pinch", "0.5", "0.5", "2"])
            == .pinch(center: center, scale: 2, duration: CommandParser.defaultGestureDuration, display: .automatic))
        #expect(try CommandParser.parse(["rotate", "0.5", "0.5", "-90", "--duration", "800"])
            == .rotate(center: center, degrees: -90, duration: .milliseconds(800), display: .automatic))
        expectUsageError { try CommandParser.parse(["pinch", "0.5", "0.5", "0"]) }
        expectUsageError { try CommandParser.parse(["rotate", "0.5", "0.5", "0"]) }
        expectUsageError { try CommandParser.parse(["rotate", "0.5", "0.5"]) }
    }

    @Test func swipeDefaultsAndOptions() throws {
        let plain = try CommandParser.parse(["swipe", "0.5", "0.9", "0.5", "0.1"])
        #expect(plain == .swipe(path: [.normalized(CGPoint(x: 0.5, y: 0.9)), .normalized(CGPoint(x: 0.5, y: 0.1))],
                                duration: CommandParser.defaultSwipeDuration, edge: nil, display: .automatic))
        let edge = try CommandParser.parse(["swipe", "0.5", "0.99", "0.5", "0.5", "--edge", "bottom", "--duration", "250", "--display", "cover"])
        #expect(edge == .swipe(path: [.normalized(CGPoint(x: 0.5, y: 0.99)), .normalized(CGPoint(x: 0.5, y: 0.5))],
                               duration: .milliseconds(250), edge: .bottom, display: .cover))
    }

    @Test func swipesTakeMorePointsInPairs() throws {
        let bent = try CommandParser.parse(["swipe", "0.5", "0.99", "0.5", "0.95", "0.9", "0.95"])
        #expect(bent == .swipe(path: [.normalized(CGPoint(x: 0.5, y: 0.99)), .normalized(CGPoint(x: 0.5, y: 0.95)),
                                      .normalized(CGPoint(x: 0.9, y: 0.95))],
                               duration: CommandParser.defaultSwipeDuration, edge: nil, display: .automatic))
        #expect(throws: SimDriveError.self) { try CommandParser.parse(["swipe", "0.5", "0.99", "0.5"]) }
        #expect(throws: SimDriveError.self) { try CommandParser.parse(["swipe", "0.5", "0.99", "0.5", "0.95", "0.9"]) }
    }

    @Test func splitTakesALayoutAndOptionallyTheCurrentOne() throws {
        #expect(try CommandParser.parse(["split", "right"]) == .split(.right, from: nil))
        #expect(try CommandParser.parse(["split", "full", "--from", "left"]) == .split(.full, from: .left))
        #expect(throws: SimDriveError.self) { try CommandParser.parse(["split"]) }
        #expect(throws: SimDriveError.self) { try CommandParser.parse(["split", "top"]) }
        #expect(throws: SimDriveError.self) { try CommandParser.parse(["split", "full", "--from", "middle"]) }
    }

    @Test func postureAndOrientationReadWithoutAnArgument() throws {
        #expect(try CommandParser.parse(["posture"]) == .posture(nil))
        #expect(try CommandParser.parse(["posture", "half"]) == .posture(.partiallyOpen))
        #expect(try CommandParser.parse(["orientation"]) == .orientation(nil))
        #expect(try CommandParser.parse(["orientation", "upside-down"]) == .orientation(.portraitUpsideDown))
    }

    @Test func buttonDefaultsAndOptions() throws {
        #expect(try CommandParser.parse(["button", "home"]) == .button(.home, count: 1, hold: CommandParser.defaultButtonHold, legacy: false))
        #expect(try CommandParser.parse(["button", "play-pause", "--repeat", "2", "--hold", "800"])
            == .button(.playPause, count: 2, hold: .milliseconds(800), legacy: false))
        #expect(try CommandParser.parse(["button", "lock", "--legacy"])
            == .button(.lock, count: 1, hold: CommandParser.defaultButtonHold, legacy: true))
        expectUsageError { try CommandParser.parse(["button", "select", "--hold", "0"]) }
        expectUsageError { try CommandParser.parse(["button", "power"]) }
    }

    /// The Action button acts only when held, so its default hold is longer; --hold still overrides it.
    @Test func actionButtonHoldsLongerByDefault() throws {
        #expect(try CommandParser.parse(["button", "action"])
            == .button(.action, count: 1, hold: CommandParser.actionButtonHold, legacy: false))
        #expect(try CommandParser.parse(["button", "action", "--hold", "100"])
            == .button(.action, count: 1, hold: .milliseconds(100), legacy: false))
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
        expectUsageError { try CommandParser.parse(["setting", "sepia-mode", "on"]) }
        #expect(try CommandParser.parse(["setting", "color-filter", "deuteranopia"])
            == .setting(SettingCatalog.setting(named: "color-filter"), value: "deuteranopia"))
        expectUsageError { try CommandParser.parse(["setting", "bold-text", "maybe"]) }
        expectUsageError { try CommandParser.parse(["setting", "bold-text", "on", "now"]) }
    }

    @Test func openURLTakesAURLWithAScheme() throws {
        #expect(try CommandParser.parse(["openurl", "myapp://item/1?x=2"]) == .openURL("myapp://item/1?x=2"))
        expectUsageError { try CommandParser.parse(["openurl", "no scheme"]) }
        expectUsageError { try CommandParser.parse(["openurl"]) }
    }

    @Test func pushTakesABundleIdentifierAndAPayloadFileOrInlinedJSON() throws {
        #expect(try CommandParser.parse(["push", "com.example.app", "push.json"])
                == .push(bundleID: "com.example.app", payload: .file("push.json")))
        #expect(try CommandParser.parse(["push", "com.example.app", "--json", "{\"aps\":{}}"])
                == .push(bundleID: "com.example.app", payload: .json("{\"aps\":{}}")))
        expectUsageError { try CommandParser.parse(["push", "com.example.app"]) }
        expectUsageError { try CommandParser.parse(["push", "com.example.app", "a.json", "b.json"]) }
    }

    @Test func privacyNeedsABundleIdentifierExceptToReset() throws {
        #expect(try CommandParser.parse(["privacy", "grant", "photos", "com.example.app"])
                == .privacy(.grant, service: "photos", bundleID: "com.example.app"))
        #expect(try CommandParser.parse(["privacy", "reset", "all"]) == .privacy(.reset, service: "all", bundleID: nil))
        expectUsageError { try CommandParser.parse(["privacy", "grant", "photos"]) }
        expectUsageError { try CommandParser.parse(["privacy", "allow", "photos", "com.example.app"]) }
        expectUsageError { try CommandParser.parse(["privacy"]) }
    }

    @Test func statusBarOverridesCheckedValuesOrClears() throws {
        let parsed = try CommandParser.parse(["status-bar", "override", "--time", "9:41", "--battery", "100", "--operator", ""])
        #expect(parsed == .statusBar(try StatusBarOverride(["time": "9:41", "battery": "100", "operator": ""])))
        #expect(try CommandParser.parse(["status-bar", "clear"]) == .statusBar(nil))
        expectUsageError { try CommandParser.parse(["status-bar", "override"]) }
        expectUsageError { try CommandParser.parse(["status-bar", "override", "--battery", "101"]) }
        expectUsageError { try CommandParser.parse(["status-bar", "override", "--wifi-bars", "4"]) }
        expectUsageError { try CommandParser.parse(["status-bar", "override", "--battery-state", "full"]) }
        expectUsageError { try CommandParser.parse(["status-bar", "clear", "now"]) }
        expectUsageError { try CommandParser.parse(["status-bar"]) }
    }

    /// simctl's flags come in a fixed order, whatever order the options came in.
    @Test func statusBarOverridePassesSimctlFlags() throws {
        let override = try StatusBarOverride(["cellular-bars": "4", "time": "9:41", "battery-state": "charged"])
        #expect(override.simctlArguments == ["--time", "9:41", "--batteryState", "charged", "--cellularBars", "4"])
    }

    @Test func treeTakesCoveredAndAnAppForAWholeTree() throws {
        #expect(try CommandParser.parse(["tree", "--covered"]) == .tree(at: nil, detail: .light, covered: true))
        #expect(try CommandParser.parse(["tree", "--app", "com.example.app", "--full"])
                == .tree(at: nil, detail: .full, app: "com.example.app"))
        expectUsageError { try CommandParser.parse(["tree", "--covered", "--full"]) }
        expectUsageError { try CommandParser.parse(["tree", "0.5", "0.5", "--covered"]) }
        expectUsageError { try CommandParser.parse(["tree", "0.5", "0.5", "--app", "com.example.app"]) }
    }

    @Test func shakeTakesNoArguments() throws {
        #expect(try CommandParser.parse(["shake"]) == .shake)
        expectUsageError { try CommandParser.parse(["shake", "twice"]) }
    }

    @Test func memoryWarningTakesNoArguments() throws {
        #expect(try CommandParser.parse(["memory-warning"]) == .memoryWarning)
        expectUsageError { try CommandParser.parse(["memory-warning", "critical"]) }
    }

    @Test func installTakesAPathAndUninstallABundleIdentifier() throws {
        #expect(try CommandParser.parse(["install", "build/My App.ipa"]) == .install(path: "build/My App.ipa"))
        #expect(try CommandParser.parse(["uninstall", "com.example"]) == .uninstall(bundleID: "com.example"))
        expectUsageError { try CommandParser.parse(["install"]) }
        expectUsageError { try CommandParser.parse(["uninstall", "a", "b"]) }
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
