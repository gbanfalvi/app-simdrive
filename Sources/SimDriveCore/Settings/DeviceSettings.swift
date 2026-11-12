import Foundation
import SimDriveNative

/// Reads and changes the settings of `SettingCatalog`.
@MainActor
final class DeviceSettings {
    /// What `simctl ui` reads for an option the device lacks.
    private static let unsupportedReading = "unsupported"

    private let udid: String
    private let device: SimulatorDevice
    private let tools: DeveloperTools
    private let preferences: GuestPreferences

    init(udid: String, device: SimulatorDevice, tools: DeveloperTools) {
        self.udid = udid
        self.device = device
        self.tools = tools
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
        guard setting.isAvailable(onOSVersion: device.majorOSVersion) else { throw unsupported(setting) }
        switch setting.storage {
        case .interface(let option):
            guard try await Self.interfaceReading(option, udid: udid, tools: tools) != Self.unsupportedReading else {
                throw unsupported(setting)
            }
            try await tools.simctl(["ui", udid, option, setting.interfaceArgument(for: value)])
        case .preference(let domain, let key, _, let notifications):
            try await preferences.write(setting.preferenceValue(for: value), forKey: key, in: domain)
            for notification in notifications {
                try device.postDarwinNotification(notification)
            }
        }
        return try await read(setting)
    }

    func value(of setting: Setting) async throws -> JSONValue {
        try await values(of: [setting])[setting.name] ?? .null
    }

    /// Each preference domain is exported once, and every read runs concurrently.
    private func values(of settings: [Setting]) async throws -> [String: JSONValue] {
        let (udid, tools, preferences) = (udid, tools, preferences)
        let version = device.majorOSVersion
        let available = settings.filter { $0.isAvailable(onOSVersion: version) }
        var keysByDomain: [String: [(setting: Setting, key: String)]] = [:]
        for setting in available {
            if case .preference(let domain, let key, _, _) = setting.storage { keysByDomain[domain, default: []].append((setting, key)) }
        }
        return try await withThrowingTaskGroup(of: [String: JSONValue].self) { group in
            for setting in available {
                guard case .interface(let option) = setting.storage else { continue }
                group.addTask {
                    let reading = try await Self.interfaceReading(option, udid: udid, tools: tools)
                    return [setting.name: setting.value(fromInterfaceReading: reading)]
                }
            }
            for (domain, keys) in keysByDomain {
                group.addTask {
                    let stored = try await preferences.export(domain)
                    return Dictionary(uniqueKeysWithValues: keys.map { ($0.setting.name, $0.setting.value(fromPreference: stored[$0.key])) })
                }
            }
            var values = Dictionary(uniqueKeysWithValues: settings.filter { !$0.isAvailable(onOSVersion: version) }.map {
                ($0.name, JSONValue.unsupported)
            })
            for try await part in group {
                values.merge(part) { current, _ in current }
            }
            return values
        }
    }

    private func unsupported(_ setting: Setting) -> SimDriveError {
        SimDriveError(.settingUnsupported, "\(device.name) has no \(setting.name) setting.")
    }

    nonisolated private static func interfaceReading(_ option: String, udid: String, tools: DeveloperTools) async throws -> String {
        try await tools.simctl(["ui", udid, option]).standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
