import Foundation
import SimDriveNative

/// Reads and changes the settings of `SettingCatalog`. A simulator keeps each setting in its row's first storage; a
/// physical device reaches only CoreDevice's setting actions, so it uses the first of those and lacks the rest.
@MainActor
final class DeviceSettings {
    private let id: String
    private let name: String
    private let majorOSVersion: Int?
    /// Nil on a physical device.
    private let simulator: SimulatorDevice?
    private let tools: DeveloperTools
    private let preferences: GuestPreferences?
    private let actions: @MainActor () async throws -> GuestSettingActions

    init(id: String, name: String, majorOSVersion: Int?, simulator: SimulatorDevice?, tools: DeveloperTools,
         actions: @escaping @MainActor () async throws -> GuestSettingActions) {
        self.id = id
        self.name = name
        self.majorOSVersion = majorOSVersion
        self.simulator = simulator
        self.tools = tools
        self.actions = actions
        preferences = simulator.map { simulator in
            GuestPreferences(udid: id, tools: tools,
                             directory: simulator.dataDirectory?.appendingPathComponent("Library/Preferences", isDirectory: true))
        }
    }

    func all() async throws -> JSONValue {
        ["settings": .object(try await values(of: SettingCatalog.all))]
    }

    func read(_ setting: Setting) async throws -> JSONValue {
        ["setting": .string(setting.name), "value": try await value(of: setting)]
    }

    /// Writes the value, tells running apps, and reads it back.
    func set(_ setting: Setting, to value: JSONValue) async throws -> JSONValue {
        guard isAvailable(setting), let storage = storage(of: setting) else { throw unsupported(setting) }
        switch (storage, simulator) {
        case (.interface(let option), let simulator?):
            guard simulator.interfaceChoice(option) != nil, let choice = setting.interfaceChoice(for: value) else {
                throw unsupported(setting)
            }
            try simulator.setInterfaceChoice(option, to: choice)
        case (.preference, let simulator?):
            try await writePreference(value, of: setting, on: simulator)
            if let service = setting.service, value == true {
                try await enableApplicationAccessibility()
                try await start(service)
            }
        case (.coreDevice(let field), _):
            let actions = try await actions()
            guard try await actions.supports(field.action) else { throw unsupported(setting) }
            let current = field.needsCurrentValue ? try await actions.value(of: field.action) : [:]
            let context = CoreDeviceSetting.Context(current: current, filterType: { try await actions.colorFilterType($0) })
            guard let input = try await field.input(for: value, in: context) else {
                throw SimDriveError(.settingUnsupported, field == .colorFilterIntensity
                    ? "Turn on a color filter other than grayscale with color-filter before setting its intensity."
                    : "\(name) has no \(setting.name) setting.")
            }
            try await actions.set(field.action, input: input)
        case (.notificationState(let notification, _), let simulator?):
            try simulator.setDarwinNotificationState(value == true ? 1 : 0, of: notification)
            try simulator.postDarwinNotification(notification)
        case (.interface, nil), (.preference, nil), (.notificationState, nil):
            throw unsupported(setting)
        }
        return try await read(setting)
    }

    func value(of setting: Setting) async throws -> JSONValue {
        try await values(of: [setting])[setting.name] ?? .null
    }

    /// Apps launched while it is off answer no accessibility reads until they relaunch. Simulators only.
    func enableApplicationAccessibility() async throws {
        guard let simulator else { return }
        try await writePreference(true, of: SettingCatalog.applicationAccessibility, on: simulator)
    }

    func isApplicationAccessibilityEnabled() async throws -> Bool {
        try await value(of: SettingCatalog.applicationAccessibility) == true
    }

    /// The storage this device keeps the setting in: a simulator's first, or a physical device's first setting action.
    private func storage(of setting: Setting) -> Setting.Storage? {
        guard simulator == nil else { return setting.storage }
        return setting.storages.first { if case .coreDevice = $0 { true } else { false } }
    }

    /// Each preference domain is exported once, and every read runs concurrently.
    private func values(of settings: [Setting]) async throws -> [String: JSONValue] {
        var keysByDomain: [String: [(setting: Setting, key: String)]] = [:]
        var fieldsByAction: [GuestSetting: [(setting: Setting, field: CoreDeviceSetting)]] = [:]
        var values: [String: JSONValue] = [:]
        for setting in settings {
            guard isAvailable(setting), let storage = storage(of: setting) else {
                values[setting.name] = .unsupported
                continue
            }
            switch (storage, simulator) {
            case (.interface(let option), let simulator?):
                values[setting.name] = setting.value(fromInterfaceChoice: simulator.interfaceChoice(option))
            case (.preference(let domain, let key, _, _), _): keysByDomain[domain, default: []].append((setting, key))
            case (.coreDevice(let field), _): fieldsByAction[field.action, default: []].append((setting, field))
            case (.notificationState(let notification, _), let simulator?):
                values[setting.name] = .bool(try simulator.darwinNotificationState(notification) != 0)
            case (.interface, nil), (.notificationState, nil):
                values[setting.name] = .unsupported
            }
        }
        // One read per action. A device without the action's service, or whose guest refuses the read, lacks its settings;
        // a read that may work again, such as a timeout under load, fails the command instead of reading as unsupported (F30).
        for (action, fields) in fieldsByAction {
            let output = try await readIfSupported(action)
            for (setting, field) in fields { values[setting.name] = output.map(field.value) ?? .unsupported }
        }
        guard let preferences, !keysByDomain.isEmpty else { return values }
        return try await withThrowingTaskGroup(of: [String: JSONValue].self) { [values] group in
            for (domain, keys) in keysByDomain {
                group.addTask {
                    let stored = try await preferences.export(domain)
                    return Dictionary(uniqueKeysWithValues: keys.map { ($0.setting.name, $0.setting.value(fromPreference: stored[$0.key])) })
                }
            }
            var values = values
            for try await part in group {
                values.merge(part) { current, _ in current }
            }
            return values
        }
    }

    private func readIfSupported(_ action: GuestSetting) async throws -> [String: Any]? {
        do {
            let actions = try await actions()
            guard try await actions.supports(action) else { return nil }
            return try await actions.value(of: action)
        } catch let error as SimDriveError where !error.code.isRetryable {
            return nil
        }
    }

    private func writePreference(_ value: JSONValue, of setting: Setting, on simulator: SimulatorDevice) async throws {
        guard case .preference(let domain, let key, _, let notifications) = setting.storage, let preferences else { return }
        try await preferences.write(setting.preferenceValue(for: value), forKey: key, in: domain)
        for notification in notifications {
            try simulator.postDarwinNotification(notification)
        }
    }

    private func isAvailable(_ setting: Setting) -> Bool {
        guard setting.isAvailable(onOSVersion: majorOSVersion) else { return false }
        guard let simulator else { return true }
        guard setting.service.map(simulator.hasLaunchDaemon) ?? true else { return false }
        if case .notificationState(_, let feature) = setting.storage { return simulator.supportsFeature(feature) }
        return true
    }

    /// The guest's launchd domain belongs to the host user, who runs the simulator.
    private func start(_ service: String) async throws {
        try await tools.simctl(["spawn", id, "launchctl", "kickstart", "user/\(getuid())/\(service)"])
    }

    private func unsupported(_ setting: Setting) -> SimDriveError {
        SimDriveError(.settingUnsupported, "\(name) has no \(setting.name) setting.")
    }
}
