import CoreGraphics
import Foundation
import SimDriveNative

/// A point of a screen: unit fractions of the screenshot, or pixels of the last screenshot's image.
package enum ScreenPoint: Equatable, Sendable {
    case unit(CGPoint)
    case pixels(CGPoint)

    private static let unitRange: ClosedRange<Double> = 0...1

    /// Values in 0...1 written with a decimal point are unit fractions; anything else is pixels.
    init?(x: String, y: String) {
        guard let xValue = Double(x), let yValue = Double(y), xValue >= 0, yValue >= 0 else { return nil }
        let point = CGPoint(x: xValue, y: yValue)
        let isUnit = Self.unitRange.contains(xValue) && Self.unitRange.contains(yValue) && (x.contains(".") || y.contains("."))
        self = isUnit ? .unit(point) : .pixels(point)
    }

    var usesPixels: Bool {
        if case .pixels = self { return true }
        return false
    }
}

/// Hardware and Apple TV Remote buttons, as HID consumer-page usages. On tvOS, home is the TV button.
package enum HardwareButton: String, CaseIterable, Sendable {
    case home, lock, volumeUp = "volume-up", volumeDown = "volume-down", siri
    case menu, select, playPause = "play-pause", up, down, left, right, channelUp = "channel-up", channelDown = "channel-down"

    static let usagePage: UInt16 = 0x0C

    var usage: UInt16 {
        switch self {
        case .home: 0x40
        case .lock: 0x30
        case .volumeUp: 0xE9
        case .volumeDown: 0xEA
        case .siri: 0xCF
        case .menu: 0x223
        case .select: 0x41
        case .playPause: 0xCD
        case .up: 0x42
        case .down: 0x43
        case .left: 0x44
        case .right: 0x45
        case .channelUp: 0x9C
        case .channelDown: 0x9D
        }
    }
}

package enum Command: Equatable, Sendable {
    case key(name: String, modifiers: Set<KeyModifier>, count: Int)
    case type(text: String)
    case tap(ScreenPoint, display: DisplaySelector)
    case swipe(from: ScreenPoint, to: ScreenPoint, duration: Duration, edge: ScreenEdge?, display: DisplaySelector)
    case button(HardwareButton, count: Int, hold: Duration)
    case posture(DevicePosture?)
    case orientation(DeviceOrientation?)
    case pasteboard(text: String?)
    case screenshot(path: String, display: DisplaySelector, maxDimension: Int)
    case launch(bundleID: String, arguments: [String])
    case wait(milliseconds: Int)
    case run(steps: [[String]])
    case doctor
    case stop
    case serve

    /// Whether the command can be a step of `run`.
    var isStep: Bool {
        switch self {
        case .run, .stop, .serve: false
        default: true
        }
    }
}

package struct UsageError: LocalizedError, Equatable, Sendable {
    package let message: String

    init(_ message: String) { self.message = message }

    package var errorDescription: String? { "\(message). Run `simdrive help` for usage." }
}

package enum CommandParser {
    package static let defaultMaxDimension = 1024
    package static let defaultSwipeDuration: Duration = .milliseconds(300)
    package static let defaultButtonHold: Duration = .milliseconds(100)
    private static let postureNames: [String: DevicePosture] = [
        "closed": .closed, "half": .partiallyOpen, "partially-open": .partiallyOpen, "partiallyOpen": .partiallyOpen, "open": .open,
    ]

    package static func parse(_ arguments: [String]) throws -> Command {
        guard let name = arguments.first else { throw UsageError("Missing command") }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "key":
            let list = try ArgumentList(rest, options: ["mods", "repeat"])
            let key = try list.single("a key name")
            guard KeyMap.stroke(named: key) != nil else {
                throw UsageError("Unknown key \"\(key)\"; use a US-layout character or one of \(KeyMap.keyNames.joined(separator: ", "))")
            }
            return .key(name: key, modifiers: try modifiers(list.option("mods")), count: try list.positiveInteger("repeat") ?? 1)
        case "type":
            return .type(text: try ArgumentList(rest).single("the text"))
        case "tap":
            let list = try ArgumentList(rest, options: ["display"])
            let values = try list.exactly(2, "x and y")
            return .tap(try point(values[0], values[1]), display: try display(list.option("display")))
        case "swipe":
            let list = try ArgumentList(rest, options: ["display", "duration", "edge"])
            let values = try list.exactly(4, "x1 y1 x2 y2")
            let duration = try list.positiveInteger("duration").map { Duration.milliseconds($0) } ?? defaultSwipeDuration
            return .swipe(from: try point(values[0], values[1]), to: try point(values[2], values[3]), duration: duration,
                          edge: try edge(list.option("edge")), display: try display(list.option("display")))
        case "button":
            let list = try ArgumentList(rest, options: ["repeat", "hold"])
            let value = try list.single("a button")
            guard let button = HardwareButton(rawValue: value) else {
                throw UsageError("Unknown button \"\(value)\"; use \(HardwareButton.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let hold = try list.positiveInteger("hold").map { Duration.milliseconds($0) } ?? defaultButtonHold
            return .button(button, count: try list.positiveInteger("repeat") ?? 1, hold: hold)
        case "posture":
            guard let value = try ArgumentList(rest).optionalSingle() else { return .posture(nil) }
            guard let posture = postureNames[value] else { throw UsageError("Unknown posture \"\(value)\"; use closed, half or open") }
            return .posture(posture)
        case "orientation":
            guard let value = try ArgumentList(rest).optionalSingle() else { return .orientation(nil) }
            guard let orientation = DeviceOrientation(name: value) else {
                throw UsageError("Unknown orientation \"\(value)\"; use portrait, landscape-left, landscape-right or upside-down")
            }
            return .orientation(orientation)
        case "pasteboard":
            return .pasteboard(text: try ArgumentList(rest).optionalSingle())
        case "screenshot":
            let list = try ArgumentList(rest, options: ["display", "max-dim"])
            let maxDimension = try list.integer("max-dim") ?? defaultMaxDimension
            guard maxDimension >= 0 else { throw UsageError("--max-dim must not be negative") }
            return .screenshot(path: try list.single("an output path"), display: try display(list.option("display")),
                               maxDimension: maxDimension)
        case "launch":
            let list = try ArgumentList(rest)
            guard let bundleID = list.positionals.first else { throw UsageError("launch needs a bundle identifier") }
            return .launch(bundleID: bundleID, arguments: Array(list.positionals.dropFirst()))
        case "wait":
            guard let milliseconds = Int(try ArgumentList(rest).single("milliseconds")), milliseconds >= 0 else {
                throw UsageError("wait needs milliseconds")
            }
            return .wait(milliseconds: milliseconds)
        case "run":
            let list = try ArgumentList(rest, options: ["json"])
            if let json = list.option("json") { return .run(steps: try Steps.parse(Data(json.utf8))) }
            let path = try list.single("a steps file")
            return .run(steps: try Steps.parse(try Data(contentsOf: URL(fileURLWithPath: path))))
        case "doctor":
            try ArgumentList(rest).none()
            return .doctor
        case "stop":
            try ArgumentList(rest).none()
            return .stop
        case "serve":
            try ArgumentList(rest).none()
            return .serve
        default:
            throw UsageError("Unknown command \"\(name)\"")
        }
    }

    private static func point(_ x: String, _ y: String) throws -> ScreenPoint {
        guard let point = ScreenPoint(x: x, y: y) else { throw UsageError("\(x) \(y) is not a point") }
        return point
    }

    private static func display(_ value: String?) throws -> DisplaySelector {
        guard let value else { return .automatic }
        guard let display = DisplaySelector(name: value) else { throw UsageError("Unknown display \"\(value)\"; use cover, inner or an index") }
        return display
    }

    private static func edge(_ value: String?) throws -> ScreenEdge? {
        guard let value else { return nil }
        guard let edge = ScreenEdge(rawValue: value) else { throw UsageError("Unknown edge \"\(value)\"; use top, bottom, left or right") }
        return edge
    }

    private static func modifiers(_ value: String?) throws -> Set<KeyModifier> {
        guard let value else { return [] }
        return Set(try value.split(separator: ",").map { name in
            guard let modifier = KeyModifier(name: String(name)) else { throw UsageError("Unknown modifier \"\(name)\"") }
            return modifier
        })
    }

    package static let usage = """
        simdrive: drive a booted simulator's keyboard, touchscreen, buttons and hinge. Prints one JSON object.

        usage: simdrive list
               simdrive <udid|booted> <command> [--no-daemon]

        commands:
          key <name|char> [--mods cmd,shift,alt,ctrl] [--repeat N]
          type <text>                         US-layout characters only; paste anything else
          tap <x> <y> [--display D]
          swipe <x1> <y1> <x2> <y2> [--duration ms] [--edge top|bottom|left|right] [--display D]
          button <name> [--repeat N] [--hold ms]
                 home|lock|volume-up|volume-down|siri; Apple TV Remote: menu|select|play-pause|up|down|left|right|
                 channel-up|channel-down, with home as the TV button
          posture [closed|half|open]          reads the hinge angle without an argument
          orientation [portrait|landscape-left|landscape-right|upside-down]
          pasteboard [text]                   reads the device's pasteboard, or replaces it with text
          screenshot <path.png> [--display D] [--max-dim N]   default 1024; 0 keeps full resolution
          launch <bundle-id> [args...]
          wait <ms>
          run <steps.json|->                  a JSON array of commands: ["tap 0.5 0.5", ["key", "tab"]]
          doctor
          stop                                ends the device's daemon

        Coordinates with a decimal point in 0-1 are fractions of the screen; other values are pixels of the last
        screenshot's image. D is cover, inner or a simctl display index; foldables default to the open panel.
        A daemon per device keeps the native bindings warm and exits after 10 idle minutes.
        """
}

/// Positional arguments and `--name value` options, with `--` ending options.
struct ArgumentList {
    private(set) var positionals: [String] = []
    private var options: [String: String] = [:]

    init(_ arguments: [String], options optionNames: Set<String> = []) throws {
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let token = arguments[index]
            index += 1
            guard !optionsEnded, token.hasPrefix("--") else {
                positionals.append(token)
                continue
            }
            let name = String(token.dropFirst(2))
            if name.isEmpty {
                optionsEnded = true
            } else if optionNames.contains(name) {
                guard index < arguments.count else { throw UsageError("--\(name) needs a value") }
                options[name] = arguments[index]
                index += 1
            } else {
                throw UsageError("Unknown option --\(name)")
            }
        }
    }

    func option(_ name: String) -> String? { options[name] }

    func integer(_ name: String) throws -> Int? {
        guard let value = options[name] else { return nil }
        guard let number = Int(value) else { throw UsageError("--\(name) needs an integer") }
        return number
    }

    func positiveInteger(_ name: String) throws -> Int? {
        guard let number = try integer(name) else { return nil }
        guard number > 0 else { throw UsageError("--\(name) must be positive") }
        return number
    }

    func single(_ description: String) throws -> String {
        guard positionals.count == 1 else { throw UsageError("Expected \(description)") }
        return positionals[0]
    }

    func optionalSingle() throws -> String? {
        guard positionals.count <= 1 else { throw UsageError("Expected at most one argument") }
        return positionals.first
    }

    func exactly(_ count: Int, _ description: String) throws -> [String] {
        guard positionals.count == count else { throw UsageError("Expected \(description)") }
        return positionals
    }

    func none() throws {
        guard positionals.isEmpty else { throw UsageError("Unexpected argument \(positionals[0])") }
    }
}

/// Step files: a JSON array whose elements are argument arrays or command strings.
package enum Steps {
    package static func parse(_ data: Data) throws -> [[String]] {
        guard let values = try? JSONDecoder().decode([JSONValue].self, from: data) else {
            throw UsageError("Steps must be a JSON array")
        }
        return try values.enumerated().map { index, value in
            switch value {
            case .string(let line): return try tokenize(line)
            case .array(let elements):
                return try elements.map { element in
                    guard let argument = element.argument else { throw UsageError("Step \(index + 1) has a non-scalar argument") }
                    return argument
                }
            default: throw UsageError("Step \(index + 1) is neither a string nor an array")
            }
        }
    }

    /// Splits a command line on whitespace, keeping single- or double-quoted text together.
    package static func tokenize(_ line: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken { tokens.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
                hasToken = true
            }
        }
        guard quote == nil else { throw UsageError("Unterminated quote in \"\(line)\"") }
        if hasToken { tokens.append(current) }
        return tokens
    }
}
