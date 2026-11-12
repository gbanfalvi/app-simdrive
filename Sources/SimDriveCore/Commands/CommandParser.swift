import Foundation
import SimDriveNative

struct UsageError: LocalizedError, Equatable, Sendable {
    let message: String

    init(_ message: String) { self.message = message }

    var errorDescription: String? { "\(message). Run `simdrive help` for usage." }
}

enum CommandParser {
    static let defaultMaxDimension = 1024
    static let defaultSwipeDuration: Duration = .milliseconds(300)
    static let defaultButtonHold: Duration = .milliseconds(100)
    private static let postureNames: [String: DevicePosture] = [
        "closed": .closed, "half": .partiallyOpen, "partially-open": .partiallyOpen, "partiallyOpen": .partiallyOpen, "open": .open,
    ]

    static func parse(_ arguments: [String]) throws -> Command {
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
        case "tree":
            let values = try ArgumentList(rest).positionals
            guard !values.isEmpty else { return .tree(at: nil) }
            guard values.count == 2 else { throw UsageError("Expected x and y, or nothing") }
            return .tree(at: try point(values[0], values[1]))
        case "setting":
            let values = try ArgumentList(rest).positionals
            guard let name = values.first else { return .setting(nil, value: nil) }
            guard values.count <= 2 else { throw UsageError("Expected a setting and at most one value") }
            guard let setting = SettingCatalog.setting(named: name) else {
                throw UsageError("Unknown setting \"\(name)\"; use \(SettingCatalog.all.map(\.name).joined(separator: ", "))")
            }
            guard values.count == 2 else { return .setting(setting, value: nil) }
            guard let value = setting.value(parsing: values[1]) else { throw UsageError("\(name) takes \(setting.valueDescription)") }
            return .setting(setting, value: value)
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

    static let usage = """
        simdrive: drive a booted simulator's keyboard, touchscreen, buttons and hinge, read its accessibility and change
        its settings. Prints one JSON object.

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
          tree [<x> <y>]                      the frontmost app's accessibility hierarchy, or the element at a point
          setting [<name> [<value>]]          lists every setting, or reads or changes one, such as appearance dark
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
