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
        #expect(throws: UsageError.self) { try CommandParser.parse(["key", "nope"]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["key", "a", "--mods", "hyper"]) }
        #expect(throws: UsageError.self) { try CommandParser.parse(["key", "a", "--repeat", "0"]) }
    }

    @Test func pointsWithADecimalPointInZeroToOneAreFractions() throws {
        #expect(try CommandParser.parse(["tap", "0.5", "1"]) == .tap(.unit(CGPoint(x: 0.5, y: 1)), display: .automatic))
        #expect(try CommandParser.parse(["tap", "1", "1"]) == .tap(.pixels(CGPoint(x: 1, y: 1)), display: .automatic))
        #expect(try CommandParser.parse(["tap", "120", "0.5"]) == .tap(.pixels(CGPoint(x: 120, y: 0.5)), display: .automatic))
        #expect(throws: UsageError.self) { try CommandParser.parse(["tap", "-1", "2"]) }
    }

    @Test func swipeDefaultsAndOptions() throws {
        let plain = try CommandParser.parse(["swipe", "0.5", "0.9", "0.5", "0.1"])
        #expect(plain == .swipe(from: .unit(CGPoint(x: 0.5, y: 0.9)), to: .unit(CGPoint(x: 0.5, y: 0.1)),
                                duration: CommandParser.defaultSwipeDuration, edge: nil, display: .automatic))
        let edge = try CommandParser.parse(["swipe", "0.5", "0.99", "0.5", "0.5", "--edge", "bottom", "--duration", "250", "--display", "cover"])
        #expect(edge == .swipe(from: .unit(CGPoint(x: 0.5, y: 0.99)), to: .unit(CGPoint(x: 0.5, y: 0.5)),
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
        #expect(Set(HardwareButton.allCases.map(\.usage)).count == HardwareButton.allCases.count)
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
}

struct StepsTests {
    @Test func tokenizeKeepsQuotedText() throws {
        #expect(try Steps.tokenize(#"type "hello world"  'a b' c"#) == ["type", "hello world", "a b", "c"])
        #expect(try Steps.tokenize(#"type """#) == ["type", ""])
        #expect(throws: UsageError.self) { try Steps.tokenize(#"type "open"#) }
    }

    @Test func stepsMustBeAnArrayOfStringsOrScalarArrays() {
        #expect(throws: UsageError.self) { try Steps.parse(Data(#"{"tap": 1}"#.utf8)) }
        #expect(throws: UsageError.self) { try Steps.parse(Data(#"[1]"#.utf8)) }
        #expect(throws: UsageError.self) { try Steps.parse(Data(#"[["tap", [1]]]"#.utf8)) }
    }
}

struct DisplayInfoTests {
    private let listing = """
        An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=22):
        Cannot choose between 2 displays. Specify one with --display:
            --display=3  LCD-1 (primary-1) 2007x2853
            --display=1  LCD (primary) 1398x2034
        Invalid argument
        """

    @Test func parsesTheSimctlListingByIndex() {
        let displays = DisplayInfo.parse(listing: listing)
        #expect(displays.map(\.index) == [1, 3])
        #expect(displays.map(\.role) == [DisplayInfo.coverRole, DisplayInfo.innerRole])
        #expect(displays[1].name == "LCD-1")
        #expect(displays[1].digitizerTarget == "display3")
        #expect(!displays[1].isNativeLandscape)
    }

    @Test func selectorNames() {
        #expect(DisplaySelector(name: "inner") == .inner)
        #expect(DisplaySelector(name: "2") == .index(2))
        #expect(DisplaySelector(name: "side") == nil)
    }
}

struct JSONValueTests {
    @Test func argumentsDropTheFractionOfWholeNumbers() {
        #expect(JSONValue.number(100).argument == "100")
        #expect(JSONValue.number(0.5).argument == "0.5")
        #expect(JSONValue.number(1e300).argument == "1e+300")
        #expect(JSONValue.bool(true).argument == "true")
        #expect(JSONValue.null.argument == nil)
    }
}
