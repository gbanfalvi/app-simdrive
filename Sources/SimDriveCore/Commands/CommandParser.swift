import Foundation
import SimDriveNative

enum CommandParser {
    static let defaultMaxDimension = 1024
    static let defaultSwipeDuration: Duration = .milliseconds(300)
    static let defaultButtonHold: Duration = .milliseconds(100)
    private static let postureNames: [String: DevicePosture] = [
        "closed": .closed, "half": .partiallyOpen, "partially-open": .partiallyOpen, "partiallyOpen": .partiallyOpen, "open": .open,
    ]
    private static let logScopeOptions = ["app", "process", "pid"]
    private static let logOptions: Set<String> = Set(logScopeOptions).union([
        "subsystem", "category", "level", "grep", "predicate", "source", "since", "cursor", "until", "timeout", "limit", "width",
    ])
    private static let launchStart = "launch"
    private static let durationUnits: [Character: TimeInterval] = ["s": 1, "m": 60, "h": 3600]

    static func parse(_ arguments: [String]) throws -> Command {
        guard let name = arguments.first else { throw SimDriveError.usage("Missing command") }
        let rest = Array(arguments.dropFirst())
        switch name {
        case "key":
            let list = try ArgumentList(rest, options: ["mods", "repeat"])
            let key = try list.single("a key name")
            guard KeyMap.stroke(named: key) != nil else {
                throw SimDriveError.usage(
                    "Unknown key \"\(key)\"; use a US-layout character or one of \(KeyMap.keyNames.joined(separator: ", "))")
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
                throw SimDriveError.usage(
                    "Unknown button \"\(value)\"; use \(HardwareButton.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let hold = try list.positiveInteger("hold").map { Duration.milliseconds($0) } ?? defaultButtonHold
            return .button(button, count: try list.positiveInteger("repeat") ?? 1, hold: hold)
        case "posture":
            guard let value = try ArgumentList(rest).optionalSingle() else { return .posture(nil) }
            guard let posture = postureNames[value] else {
                throw SimDriveError.usage("Unknown posture \"\(value)\"; use closed, half or open")
            }
            return .posture(posture)
        case "orientation":
            guard let value = try ArgumentList(rest).optionalSingle() else { return .orientation(nil) }
            guard let orientation = DeviceOrientation(name: value) else {
                throw SimDriveError.usage("Unknown orientation \"\(value)\"; use portrait, landscape-left, landscape-right or upside-down")
            }
            return .orientation(orientation)
        case "pasteboard":
            return .pasteboard(text: try ArgumentList(rest).optionalSingle())
        case "screenshot":
            let list = try ArgumentList(rest, options: ["display", "max-dim"])
            let maxDimension = try list.integer("max-dim") ?? defaultMaxDimension
            guard maxDimension >= 0 else { throw SimDriveError.usage("--max-dim must not be negative") }
            return .screenshot(path: try list.single("an output path"), display: try display(list.option("display")),
                               maxDimension: maxDimension)
        case "tree":
            let list = try ArgumentList(rest, flags: ["full"])
            let detail: TreeDetail = list.flag("full") ? .full : .light
            let values = list.positionals
            guard !values.isEmpty else { return .tree(at: nil, detail: detail) }
            guard values.count == 2 else { throw SimDriveError.usage("Expected x and y, or nothing") }
            return .tree(at: try point(values[0], values[1]), detail: detail)
        case "setting":
            let values = try ArgumentList(rest).positionals
            guard let name = values.first else { return .setting(nil, value: nil) }
            guard values.count <= 2 else { throw SimDriveError.usage("Expected a setting and at most one value") }
            guard let setting = SettingCatalog.setting(named: name) else {
                throw SimDriveError.usage("Unknown setting \"\(name)\"; use \(SettingCatalog.all.map(\.name).joined(separator: ", "))")
            }
            guard values.count == 2 else { return .setting(setting, value: nil) }
            guard let value = setting.value(fromArgument: values[1]) else {
                throw SimDriveError.usage("\(name) takes \(setting.valueDescription)")
            }
            return .setting(setting, value: value)
        case "launch":
            let list = try ArgumentList(rest)
            guard let bundleID = list.positionals.first else { throw SimDriveError.usage("launch needs a bundle identifier") }
            return .launch(bundleID: bundleID, arguments: Array(list.positionals.dropFirst()))
        case "wait":
            guard let milliseconds = Int(try ArgumentList(rest).single("milliseconds")), milliseconds >= 0 else {
                throw SimDriveError.usage("wait needs milliseconds")
            }
            return .wait(milliseconds: milliseconds)
        case "logs":
            return .logs(try logQuery(rest))
        case "run":
            let list = try ArgumentList(rest, options: ["json"], flags: ["logs"])
            let data = if let json = list.option("json") {
                Data(json.utf8)
            } else {
                try Data(contentsOf: URL(fileURLWithPath: try list.single("a steps file")))
            }
            return .run(steps: try steps(Steps.parse(data)), attachesLogs: list.flag("logs"))
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
            throw SimDriveError.usage("Unknown command \"\(name)\"")
        }
    }

    /// Every step is checked before any runs.
    private static func steps(_ argumentLists: [[String]]) throws -> [Step] {
        try argumentLists.enumerated().map { index, arguments in
            let command: Command
            do { command = try parse(arguments) } catch {
                throw SimDriveError(.stepInvalid, "Step \(index + 1) (\(arguments.joined(separator: " "))): \(error.localizedDescription)")
            }
            guard command.isStep else { throw SimDriveError(.stepInvalid, "Step \(index + 1) cannot be \(arguments.first ?? "")") }
            return Step(arguments: arguments, command: command)
        }
    }

    private static func logQuery(_ arguments: [String]) throws -> LogQuery {
        let list = try ArgumentList(arguments, options: logOptions, flags: ["all", "peek", "system"])
        try list.none()
        guard logScopeOptions.filter({ list.option($0) != nil }).count + (list.flag("all") ? 1 : 0) <= 1 else {
            throw SimDriveError.usage("Use one of --app, --process, --pid and --all")
        }
        var query = LogQuery()
        if let bundleID = list.option("app") { query.scope = .app(bundleID: bundleID) }
        if let name = list.option("process") { query.scope = .process(name) }
        if let pid = try list.positiveInteger("pid") { query.scope = .pid(pid) }
        if list.flag("all") { query.scope = .all }
        query.subsystem = list.option("subsystem")
        query.category = list.option("category")
        if let value = list.option("level") {
            guard let level = LogLevel(name: value) else {
                throw SimDriveError.usage("Unknown level \"\(value)\"; use \(LogLevel.allCases.map(\.name).joined(separator: ", "))")
            }
            query.level = level
        }
        query.grep = try regularExpression(list.option("grep"), option: "grep")
        query.until = try regularExpression(list.option("until"), option: "until")
        query.predicate = list.option("predicate")
        query.includesSystem = list.flag("system")
        if let value = list.option("source") { query.sources = try logSources(value) }
        if let value = list.option("since") { query.since = try logStart(value) }
        if let cursor = list.option("cursor") { query.cursor = cursor }
        query.peek = list.flag("peek")
        if let milliseconds = try list.positiveInteger("timeout") { query.timeout = .milliseconds(milliseconds) }
        if let limit = try list.integer("limit") {
            guard limit >= 0 else { throw SimDriveError.usage("--limit must not be negative") }
            query.limit = limit
        }
        if let width = try list.integer("width") {
            guard width >= 0 else { throw SimDriveError.usage("--width must not be negative") }
            query.width = width
        }
        guard query.until == nil || query.sources.contains(.log) else { throw SimDriveError.usage("--until needs the log source") }
        guard list.option("timeout") == nil || query.until != nil else { throw SimDriveError.usage("--timeout needs --until") }
        return query
    }

    private static func regularExpression(_ value: String?, option: String) throws -> String? {
        guard let value else { return nil }
        guard (try? NSRegularExpression(pattern: value)) != nil else {
            throw SimDriveError.usage("--\(option) \"\(value)\" is not a regular expression")
        }
        return value
    }

    private static func logSources(_ value: String) throws -> Set<LogQuery.Source> {
        let sources = Set(try value.split(separator: ",").map { name in
            guard let source = LogQuery.Source(rawValue: String(name)) else {
                throw SimDriveError.usage("Unknown source \"\(name)\"; use \(LogQuery.Source.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            return source
        })
        guard !sources.isEmpty else { throw SimDriveError.usage("--source needs at least one source") }
        return sources
    }

    private static func logStart(_ value: String) throws -> LogQuery.Start {
        if value == launchStart { return .launch }
        if let unit = value.last, let seconds = durationUnits[unit], let amount = Double(value.dropLast()), amount >= 0 {
            return .ago(amount * seconds)
        }
        for style in [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()] {
            if let date = try? style.parse(value) { return .date(date) }
        }
        throw SimDriveError.usage("--since takes launch, an ISO 8601 time, or a duration ago such as 30s, 5m or 1h")
    }

    private static func point(_ x: String, _ y: String) throws -> ScreenPoint {
        guard let point = ScreenPoint(x: x, y: y) else { throw SimDriveError.usage("\(x) \(y) is not a point") }
        return point
    }

    private static func display(_ value: String?) throws -> DisplaySelector {
        guard let value else { return .automatic }
        guard let display = DisplaySelector(name: value) else {
            throw SimDriveError.usage("Unknown display \"\(value)\"; use cover, inner or an index")
        }
        return display
    }

    private static func edge(_ value: String?) throws -> ScreenEdge? {
        guard let value else { return nil }
        guard let edge = ScreenEdge(rawValue: value) else {
            throw SimDriveError.usage("Unknown edge \"\(value)\"; use top, bottom, left or right")
        }
        return edge
    }

    private static func modifiers(_ value: String?) throws -> Set<KeyModifier> {
        guard let value else { return [] }
        return Set(try value.split(separator: ",").map { name in
            guard let modifier = KeyModifier(name: String(name)) else { throw SimDriveError.usage("Unknown modifier \"\(name)\"") }
            return modifier
        })
    }

    static let usage = """
        simdrive: drive a booted simulator's keyboard, touchscreen, buttons and hinge, read its accessibility and logs,
        and change its settings. Prints one JSON object.

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
          tree [<x> <y>] [--full]             the frontmost app's VoiceOver elements, or the element at a point;
                                              --full adds every node and field, nested
          setting [<name> [<value>]]          lists every setting, or reads or changes one, such as appearance dark
          launch <bundle-id> [args...]
          wait <ms>
          logs [scope] [filters] [--since S] [--cursor NAME] [--peek] [--until <regex> [--timeout ms]]
               [--limit N] [--width N]        the launched app's log entries, stdout, stderr and crashes since the
                                              cursor's last read; --until waits for a matching entry, 5000 ms by default
               scope: --app <bundle-id> | --process <name> | --pid <n> | --all
               filters: --level debug|info|default|error|fault --subsystem S --category C --grep <regex>
                        --predicate <NSPredicate> --source log,stdout,crash
                        --system keeps an app's system-library entries below error level
               S: launch, an ISO 8601 time, or a duration ago such as 30s; --limit 50 and --width 240 by default
          run <steps.json|-> [--logs]         a JSON array of commands: ["tap 0.5 0.5", ["key", "tab"]];
                                              --logs adds each step's log entries to its result
          doctor
          stop                                ends the device's daemon

        Coordinates with a decimal point in 0-1 are fractions of the screen; other values are pixels of the last
        screenshot's image. D is cover, inner or a simctl display index; foldables default to the open panel.
        A daemon per device keeps the native bindings warm and exits after 10 idle minutes.
        """
}

/// Positional arguments, `--name value` options and `--name` flags, with `--` ending options.
struct ArgumentList {
    private(set) var positionals: [String] = []
    private var options: [String: String] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String], options optionNames: Set<String> = [], flags flagNames: Set<String> = []) throws {
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
            } else if flagNames.contains(name) {
                flags.insert(name)
            } else if optionNames.contains(name) {
                guard index < arguments.count else { throw SimDriveError.usage("--\(name) needs a value") }
                options[name] = arguments[index]
                index += 1
            } else {
                throw SimDriveError.usage("Unknown option --\(name)")
            }
        }
    }

    func option(_ name: String) -> String? { options[name] }

    func flag(_ name: String) -> Bool { flags.contains(name) }

    func integer(_ name: String) throws -> Int? {
        guard let value = options[name] else { return nil }
        guard let number = Int(value) else { throw SimDriveError.usage("--\(name) needs an integer") }
        return number
    }

    func positiveInteger(_ name: String) throws -> Int? {
        guard let number = try integer(name) else { return nil }
        guard number > 0 else { throw SimDriveError.usage("--\(name) must be positive") }
        return number
    }

    func single(_ description: String) throws -> String {
        guard positionals.count == 1 else { throw SimDriveError.usage("Expected \(description)") }
        return positionals[0]
    }

    func optionalSingle() throws -> String? {
        guard positionals.count <= 1 else { throw SimDriveError.usage("Expected at most one argument") }
        return positionals.first
    }

    func exactly(_ count: Int, _ description: String) throws -> [String] {
        guard positionals.count == count else { throw SimDriveError.usage("Expected \(description)") }
        return positionals
    }

    func none() throws {
        guard positionals.isEmpty else { throw SimDriveError.usage("Unexpected argument \(positionals[0])") }
    }
}
