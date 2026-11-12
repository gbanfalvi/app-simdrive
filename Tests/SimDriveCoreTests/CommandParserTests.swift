import CoreGraphics
import SimDriveNative
import Testing
@testable import SimDriveCore

struct CommandParserTests {
    @Test func keyWithModifiersAndRepeat() throws {
        let command = try CommandParser.parse(["key", "tab", "--mods", "cmd,shift", "--repeat", "3"])
        #expect(command == .key(name: "tab", modifiers: [.command, .shift], count: 3))
    }

    @Test func keyRejectsUnknownNamesAndModifiers() {
        #expect(throws: UsageError.self) { try CommandParser.parse(["key", "nope"]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["key", "a", "--mods", "hyper"]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["key", "a", "--repeat", "0"]) }
    }

    @Test func pointsWithADecimalPointInZeroToOneAreFractions() throws {
        #expect(try CommandParser.parse(["tap", "0.5", "1"]) == .tap(.normalized(CGPoint(x: 0.5, y: 1)), display: .automatic))
        #expect(try CommandParser.parse(["tap", "1", "1"]) == .tap(.pixels(CGPoint(x: 1, y: 1)), display: .automatic))
        #expect(try CommandParser.parse(["tap", "120", "0.5"]) == .tap(.pixels(CGPoint(x: 120, y: 0.5)), display: .automatic))
        #expect(throws: UsageError.self) { try CommandParser.parse(["tap", "-1", "2"]) }
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
        #expect(throws: UsageError.self) { try CommandParser.parse(["button", "select", "--hold", "0"]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["button", "power"]) }
    }

    @Test func pasteboardReadsWithoutAnArgument() throws {
        #expect(try CommandParser.parse(["pasteboard"]) == .pasteboard(text: nil))
        #expect(try CommandParser.parse(["pasteboard", "héllo wörld"]) == .pasteboard(text: "héllo wörld"))
        #expect(try CommandParser.parse(["pasteboard", ""]) == .pasteboard(text: ""))
        #expect(throws: UsageError.self) { try CommandParser.parse(["pasteboard", "a", "b"]) }
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
        #expect(throws: UsageError.self) { try CommandParser.parse(["tree", "0.5"]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["tree", "--flat"]) }
        #expect(try CommandParser.parse(["tree"]).isStep)
    }

    @Test func settingListsReadsOrChanges() throws {
        #expect(try CommandParser.parse(["setting"]) == .setting(nil, value: nil))
        #expect(try CommandParser.parse(["setting", "appearance"]) == .setting(SettingCatalog.appearance, value: nil))
        #expect(try CommandParser.parse(["setting", "appearance", "dark"]) == .setting(SettingCatalog.appearance, value: "dark"))
        #expect(try CommandParser.parse(["setting", "glass-tint", "1"]) == .setting(SettingCatalog.setting(named: "glass-tint"), value: 1))
        #expect(throws: UsageError.self) { try CommandParser.parse(["setting", "voiceover", "on"]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["setting", "bold-text", "maybe"]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["setting", "bold-text", "on", "now"]) }
    }

    @Test func launchPassesArgumentsAfterTheBundleIdentifier() throws {
        #expect(try CommandParser.parse(["launch", "com.example", "--", "--flag", "x"])
            == .launch(bundleID: "com.example", arguments: ["--flag", "x"]))
    }

    @Test func unknownCommandsAndOptionsFail() {
        #expect(throws: UsageError.self) { try CommandParser.parse([]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["fly"]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["tap", "1", "1", "--force"]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["doctor", "now"]) }
    }

    @Test func runReadsInlineSteps() throws {
        let command = try CommandParser.parse(["run", "--json", #"["tap 0.5 0.5", ["key", "tab"], ["wait", 100]]"#])
        #expect(command == .run(steps: [["tap", "0.5", "0.5"], ["key", "tab"], ["wait", "100"]]))
        #expect(!command.isStep)
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
