import Foundation
import SimDriveNative

/// Installs, removes, launches and opens apps, which `simctl` does for a simulator and `devicectl` for a physical device.
@MainActor
protocol AppControl {
    func install(_ path: String) async throws -> JSONValue
    func uninstall(_ bundleID: String) async throws -> JSONValue
    func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue
    func open(_ url: String) async throws -> JSONValue
}

/// A simulator's apps, through `simctl`: launch restarts the app with its output captured and waits until it is in front.
@MainActor
struct SimulatorApps: AppControl {
    let apps: DeviceApps
    let launcher: AppLauncher

    func install(_ path: String) async throws -> JSONValue { try await apps.install(path) }
    func uninstall(_ bundleID: String) async throws -> JSONValue { try await apps.uninstall(bundleID) }
    func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue { try await launcher.launch(bundleID, arguments: arguments) }
    func open(_ url: String) async throws -> JSONValue { try await launcher.open(url) }
}

/// A physical device's apps, through `devicectl`. A launch restarts the app but neither captures its output nor waits
/// for it to come to the front, which needs accessibility.
@MainActor
struct DeviceAppControl: AppControl {
    /// Large apps take minutes to copy over the network.
    private static let installLimit: Duration = .seconds(600)

    let id: String
    let tools: DeveloperTools
    let screens: Screens

    func install(_ path: String) async throws -> JSONValue {
        let result = try await tools.devicectl(["device", "install", "app", "--device", id, path], limit: Self.installLimit)
        let installed = (result["installedApplications"] as? [[String: Any]])?.first
        return ["bundleID": JSONValue(installed?["bundleID"] as? String)]
    }

    func uninstall(_ bundleID: String) async throws -> JSONValue {
        let installed = try await tools.devicectl(["device", "info", "apps", "--device", id, "--bundle-id", bundleID])
        guard let apps = installed["apps"] as? [[String: Any]], !apps.isEmpty else {
            throw SimDriveError(.appNotInstalled, "\(bundleID) is not installed.")
        }
        try await tools.devicectl(["device", "uninstall", "app", "--device", id, bundleID])
        return ["bundleID": .string(bundleID)]
    }

    func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue {
        let result = try await tools.devicectl(["device", "process", "launch", "--device", id, "--terminate-existing", bundleID, "--"]
                                               + arguments)
        screens.forgetScreenshots()
        let pid = (result["process"] as? [String: Any])?["processIdentifier"] as? Int
        return ["bundleID": .string(bundleID), "pid": JSONValue(pid)]
    }

    func open(_ url: String) async throws -> JSONValue {
        try await tools.devicectl(["device", "process", "openURL", "--device", id, url])
        screens.forgetScreenshots()
        return ["url": .string(url)]
    }
}
