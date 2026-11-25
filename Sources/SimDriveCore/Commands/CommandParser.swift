import Foundation
import SimDriveNative

enum CommandParser {
    static let defaultMaxDimension = 1024
    static let defaultSwipeDuration: Duration = .milliseconds(300)
    static let defaultGestureDuration: Duration = .milliseconds(500)
    private static let pinchScales: ClosedRange<Double> = 0.1...10
    static let defaultButtonHold: Duration = .milliseconds(100)
    /// As long as `logs --until` waits by default.
    static let defaultElementTimeout: Duration = .milliseconds(5000)
    static let defaultMaxSwipes = 10
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
            let list = try ArgumentList(rest, options: ["display", "label", "id", "timeout"])
            if let selector = try elementSelector(list) {
                try list.none()
                guard list.option("display") == nil else {
                    throw SimDriveError.usage("tap --label and --id read the frontmost app, so they take no --display")
                }
                return .tapElement(selector, timeout: try elementTimeout(list))
            }
            guard list.option("timeout") == nil else { throw SimDriveError.usage("--timeout needs --label or --id") }
            let values = try list.exactly(2, "x and y, or --label or --id")
            return .tap(try point(values[0], values[1]), display: try display(list.option("display")))
        case "swipe":
            let list = try ArgumentList(rest, options: ["display", "duration", "edge", "until-label", "until-id", "max-swipes"])
            let values = try list.pairs(atLeast: 2, "x1 y1 x2 y2, then optionally more x y points")
            let duration = try list.positiveInteger("duration").map { Duration.milliseconds($0) } ?? defaultSwipeDuration
            let path = try values.map { try point($0.0, $0.1) }
            if let selector = try elementSelector(list, label: "until-label", identifier: "until-id") {
                guard list.option("display") == nil, list.option("edge") == nil else {
                    throw SimDriveError.usage("swipe --until-label and --until-id read the frontmost app, so they take no --display "
                                              + "or --edge")
                }
                return .swipeUntil(path: path, duration: duration, selector: selector,
                                   maxSwipes: try list.positiveInteger("max-swipes") ?? defaultMaxSwipes)
            }
            guard list.option("max-swipes") == nil else { throw SimDriveError.usage("--max-swipes needs --until-label or --until-id") }
            return .swipe(path: path, duration: duration, edge: try edge(list.option("edge")), display: try display(list.option("display")))
        case "pinch":
            let list = try ArgumentList(rest, options: ["display", "duration"])
            let values = try list.exactly(3, "x, y and a scale")
            guard let scale = Double(values[2]), pinchScales.contains(scale) else {
                throw SimDriveError.usage("pinch needs a scale from \(pinchScales.lowerBound) to \(pinchScales.upperBound)")
            }
            return .pinch(center: try point(values[0], values[1]), scale: scale, duration: try gestureDuration(list),
                          display: try display(list.option("display")))
        case "rotate":
            let list = try ArgumentList(rest, options: ["display", "duration"])
            let values = try list.exactly(3, "x, y and degrees")
            guard let degrees = Double(values[2]), degrees.isFinite, degrees != 0 else {
                throw SimDriveError.usage("rotate needs nonzero degrees")
            }
            return .rotate(center: try point(values[0], values[1]), degrees: degrees, duration: try gestureDuration(list),
                           display: try display(list.option("display")))
        case "button":
            let list = try ArgumentList(rest, options: ["repeat", "hold"], flags: ["legacy"])
            let value = try list.single("a button")
            guard let button = HardwareButton(rawValue: value) else {
                throw SimDriveError.usage(
                    "Unknown button \"\(value)\"; use \(HardwareButton.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let hold = try list.positiveInteger("hold").map { Duration.milliseconds($0) } ?? defaultButtonHold
            return .button(button, count: try list.positiveInteger("repeat") ?? 1, hold: hold, legacy: list.flag("legacy"))
        case "posture":
            guard let value = try ArgumentList(rest).optionalSingle() else { return .posture(nil) }
            guard let posture = postureNames[value] else {
                throw SimDriveError.usage("Unknown posture \"\(value)\"; use closed, half or open")
            }
            return .posture(posture)
        case "split":
            let list = try ArgumentList(rest, options: ["from"])
            return .split(try splitLayout(list.single("a layout")), from: try list.option("from").map(splitLayout))
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
        case "install":
            return .install(path: try ArgumentList(rest).single("the path of an .app or .ipa"))
        case "uninstall":
            return .uninstall(bundleID: try ArgumentList(rest).single("a bundle identifier"))
        case "openurl":
            let text = try ArgumentList(rest).single("the URL")
            guard URL(string: text)?.scheme?.isEmpty == false else {
                throw SimDriveError.usage("openurl needs a URL with a scheme, such as myapp://path")
            }
            return .openURL(text)
        case "push":
            let list = try ArgumentList(rest, options: ["json"])
            if let json = list.option("json") {
                return .push(bundleID: try list.single("a bundle identifier, then a payload file or -"), payload: .json(json))
            }
            let positionals = try list.exactly(2, "a bundle identifier, then a payload file or -")
            return .push(bundleID: positionals[0], payload: .file(positionals[1]))
        case "privacy":
            let list = try ArgumentList(rest)
            guard (2...3).contains(list.positionals.count), let action = PrivacyAction(rawValue: list.positionals[0]) else {
                throw SimDriveError.usage("privacy needs grant, revoke or reset, a service such as photos, and a bundle identifier")
            }
            let bundleID = list.positionals.count == 3 ? list.positionals[2] : nil
            guard bundleID != nil || !action.needsBundleID else {
                throw SimDriveError.usage("privacy \(action.rawValue) needs a bundle identifier")
            }
            return .privacy(action, service: list.positionals[1], bundleID: bundleID)
        case "status-bar":
            switch rest.first {
            case "clear":
                try ArgumentList(Array(rest.dropFirst())).none()
                return .statusBar(nil)
            case "override":
                let list = try ArgumentList(Array(rest.dropFirst()), options: StatusBarOverride.options)
                try list.none()
                let values = StatusBarOverride.options.reduce(into: [String: String]()) { $0[$1] = list.option($1) }
                return .statusBar(try StatusBarOverride(values))
            default:
                throw SimDriveError.usage("status-bar needs override with values, or clear")
            }
        case "wait":
            let list = try ArgumentList(rest, options: ["label", "id", "timeout"], flags: ["absent"])
            if let selector = try elementSelector(list) {
                try list.none()
                return .waitForElement(selector, gone: list.flag("absent"), timeout: try elementTimeout(list))
            }
            guard list.option("timeout") == nil, !list.flag("absent") else {
                throw SimDriveError.usage("--timeout and --absent need --label or --id")
            }
            guard let milliseconds = Int(try list.single("milliseconds, or --label or --id")), milliseconds >= 0 else {
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
        case "shake":
            try ArgumentList(rest).none()
            return .shake
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

    /// `--label` or `--id`, or the options named instead, at most one of them, and not empty.
    private static func elementSelector(_ list: ArgumentList, label labelOption: String = "label",
                                        identifier identifierOption: String = "id") throws -> ElementSelector? {
        switch (list.option(labelOption), list.option(identifierOption)) {
        case (nil, nil): return nil
        case (_?, _?): throw SimDriveError.usage("Pass --\(labelOption) or --\(identifierOption), not both")
        case (let label?, nil):
            guard !label.isEmpty else { throw SimDriveError.usage("--\(labelOption) needs text") }
            return .label(label)
        case (nil, let identifier?):
            guard !identifier.isEmpty else { throw SimDriveError.usage("--\(identifierOption) needs an identifier") }
            return .identifier(identifier)
        }
    }

    /// How long an element command waits; 0 reads the tree once.
    private static func elementTimeout(_ list: ArgumentList) throws -> Duration {
        guard let milliseconds = try list.integer("timeout") else { return defaultElementTimeout }
        guard milliseconds >= 0 else { throw SimDriveError.usage("--timeout must not be negative") }
        return .milliseconds(milliseconds)
    }

    private static func gestureDuration(_ list: ArgumentList) throws -> Duration {
        try list.positiveInteger("duration").map { Duration.milliseconds($0) } ?? defaultGestureDuration
    }

    private static func display(_ value: String?) throws -> DisplaySelector {
        guard let value else { return .automatic }
        guard let display = DisplaySelector(name: value) else {
            throw SimDriveError.usage("Unknown display \"\(value)\"; use cover, inner or an index")
        }
        return display
    }

    private static func splitLayout(_ value: String) throws -> SplitLayout {
        guard let layout = SplitLayout(rawValue: value) else {
            throw SimDriveError.usage("Unknown layout \"\(value)\"; use left, right or full")
        }
        return layout
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
          type <text>                         on the simulator's keyboard layout; paste anything else
          tap <x> <y> [--display D]
          tap --label <text> | --id <identifier> [--timeout ms]
                                              taps the onscreen element with that exact label or identifier,
                                              waiting for it 5000 ms by default
          swipe <x1> <y1> <x2> <y2> [<x> <y> ...] [--duration ms] [--edge top|bottom|left|right] [--display D]
          swipe <x1> <y1> <x2> <y2> [<x> <y> ...] --until-label <text> | --until-id <identifier> [--max-swipes N]
                                              repeats the swipe until the element is on screen, 10 times at most
          pinch <x> <y> <scale> [--duration ms] [--display D]
                                              two fingers spread to scale times their distance, or close below 1
          rotate <x> <y> <degrees> [--duration ms] [--display D]
                                              two fingers turn around the point, clockwise when positive
          button <name> [--repeat N] [--hold ms] [--legacy]
                 --legacy presses through the route Xcode 27.3 removed, for older runtimes it may suit better
                 home|lock|volume-up|volume-down|siri; Apple TV Remote: menu|select|play-pause|up|down|left|right|
                 channel-up|channel-down, with home as the TV button
          posture [closed|half|open]          reads the hinge angle without an argument
          split left|right|full [--from left|right|full]   moves an iPhone Duo inner screen's app to a half or the whole
          orientation [portrait|landscape-left|landscape-right|upside-down]
          pasteboard [text]                   reads the device's pasteboard, or replaces it with text
          screenshot <path.png> [--display D] [--max-dim N]   default 1024; 0 keeps full resolution
          tree [<x> <y>] [--full]             the frontmost app's VoiceOver elements, or the element at a point;
                                              --full adds every node and field, nested
          setting [<name> [<value>]]          lists every setting, or reads or changes one, such as appearance dark
          launch <bundle-id> [args...]
          install <path.app|path.ipa>         installs or updates an app, returning its bundle identifier
          uninstall <bundle-id>
          openurl <url>                       opens a URL or deep link in the app that handles it
          push <bundle-id> <payload.json|->   sends a simulated remote notification; the payload has an aps key
          privacy grant|revoke|reset <service> [<bundle-id>]   sets an app's access without its alert; services
                                              as simctl privacy lists them, such as photos, location, contacts, all
          status-bar override [--time T] [--battery 0-100] [--battery-state charging|charged|discharging]
                     [--data-network wifi|5g|...] [--wifi-bars 0-3] [--cellular-bars 0-4] [--operator name]
                     [--wifi-mode M] [--cellular-mode M]
          status-bar clear                    shows the real status bar again
          shake                               shakes the device; the first responder gets motionEnded
          wait <ms>
          wait --label <text> | --id <identifier> [--absent] [--timeout ms]
                                              waits until the element is on screen, or with --absent until it is not
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

    func pairs(atLeast count: Int, _ description: String) throws -> [(String, String)] {
        guard positionals.count >= count * 2, positionals.count.isMultiple(of: 2) else {
            throw SimDriveError.usage("Expected \(description)")
        }
        return stride(from: 0, to: positionals.count, by: 2).map { (positionals[$0], positionals[$0 + 1]) }
    }

    func none() throws {
        guard positionals.isEmpty else { throw SimDriveError.usage("Unexpected argument \(positionals[0])") }
    }
}
