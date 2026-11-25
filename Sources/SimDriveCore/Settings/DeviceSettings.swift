import Foundation
import SimDriveNative

/// Reads and changes the settings of `SettingCatalog`.
@MainActor
final class DeviceSettings {
    private let udid: String
    private let device: SimulatorDevice
    private let tools: DeveloperTools
    private let preferences: GuestPreferences
    private let actions: @MainActor () async throws -> GuestSettingActions

    init(udid: String, device: SimulatorDevice, tools: DeveloperTools, actions: @escaping @MainActor () async throws -> GuestSettingActions) {
        self.udid = udid
        self.device = device
        self.tools = tools
        self.actions = actions
        preferences = GuestPreferences(udid: udid, tools: tools)
    }

    func all() async throws -> JSONValue {
        ["settings": .object(try await values(of: SettingCatalog.all))]
    }

    func read(_ setting: Setting) async throws -> JSONValue {
        ["setting": .string(setting.name), "value": try await value(of: setting)]
    }

    /// Writes the value, tells running apps, and reads it back.
    func set(_ setting: Setting, to value: JSONValue) async throws -> JSONValue {
        guard isAvailable(setting) else { throw unsupported(setting) }
        switch setting.storage {
        case .interface(let option):
            guard device.interfaceChoice(option) != nil, let choice = setting.interfaceChoice(for: value) else {
                throw unsupported(setting)
            }
            try device.setInterfaceChoice(option, to: choice)
        case .preference:
            try await writePreference(value, of: setting)
            if let service = setting.service, value == true {
                try await enableApplicationAccessibility()
                try await start(service)
            }
        case .coreDevice(let field):
            let actions = try await actions()
            guard try await actions.supports(field.action) else { throw unsupported(setting) }
            let current = field.needsCurrentValue ? try await actions.value(of: field.action) : [:]
            let context = CoreDeviceSetting.Context(current: current, filterType: { try await actions.colorFilterType($0) })
            guard let input = try await field.input(for: value, in: context) else {
                throw SimDriveError(.settingUnsupported, field == .colorFilterIntensity
                    ? "Turn on a color filter other than grayscale with color-filter before setting its intensity."
                    : "\(device.name) has no \(setting.name) setting.")
            }
            try await actions.set(field.action, input: input)
        case .notificationState(let name, _):
            try device.setDarwinNotificationState(value == true ? 1 : 0, of: name)
            try device.postDarwinNotification(name)
        }
        return try await read(setting)
    }

    func value(of setting: Setting) async throws -> JSONValue {
        try await values(of: [setting])[setting.name] ?? .null
    }

    /// Apps launched while it is off answer no accessibility reads until they relaunch.
    func enableApplicationAccessibility() async throws {
        try await writePreference(true, of: SettingCatalog.applicationAccessibility)
    }

    func isApplicationAccessibilityEnabled() async throws -> Bool {
        try await value(of: SettingCatalog.applicationAccessibility) == true
    }

    /// Each preference domain is exported once, and every read runs concurrently.
    private func values(of settings: [Setting]) async throws -> [String: JSONValue] {
        let preferences = preferences
        let available = settings.filter(isAvailable)
        var keysByDomain: [String: [(setting: Setting, key: String)]] = [:]
        var fieldsByAction: [GuestSetting: [(setting: Setting, field: CoreDeviceSetting)]] = [:]
        var values = Dictionary(uniqueKeysWithValues: settings.filter { !available.contains($0) }.map {
            ($0.name, JSONValue.unsupported)
        })
        for setting in available {
            switch setting.storage {
            case .interface(let option): values[setting.name] = setting.value(fromInterfaceChoice: device.interfaceChoice(option))
            case .preference(let domain, let key, _, _): keysByDomain[domain, default: []].append((setting, key))
            case .coreDevice(let field): fieldsByAction[field.action, default: []].append((setting, field))
            case .notificationState(let name, _): values[setting.name] = .bool(try device.darwinNotificationState(name) != 0)
            }
        }
        // One read per action. A device without the action's service, or whose guest refuses the read, lacks its settings;
        // a read that may work again, such as a timeout under load, fails the command instead of reading as unsupported (F30).
        for (action, fields) in fieldsByAction {
            let output = try await readIfSupported(action)
            for (setting, field) in fields { values[setting.name] = output.map(field.value) ?? .unsupported }
        }
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

    private func writePreference(_ value: JSONValue, of setting: Setting) async throws {
        guard case .preference(let domain, let key, _, let notifications) = setting.storage else { return }
        try await preferences.write(setting.preferenceValue(for: value), forKey: key, in: domain)
        for notification in notifications {
            try device.postDarwinNotification(notification)
        }
    }

    private func isAvailable(_ setting: Setting) -> Bool {
        guard setting.isAvailable(onOSVersion: device.majorOSVersion), setting.service.map(device.hasLaunchDaemon) ?? true else {
            return false
        }
        if case .notificationState(_, let feature) = setting.storage { return device.supportsFeature(feature) }
        return true
    }

    /// The guest's launchd domain belongs to the host user, who runs the simulator.
    private func start(_ service: String) async throws {
        try await tools.simctl(["spawn", udid, "launchctl", "kickstart", "user/\(getuid())/\(service)"])
    }

    private func unsupported(_ setting: Setting) -> SimDriveError {
        SimDriveError(.settingUnsupported, "\(device.name) has no \(setting.name) setting.")
    }
}
