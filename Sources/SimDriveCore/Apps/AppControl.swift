import Foundation
import SimDriveNative

/// Installs, removes, launches and opens apps, which `simctl` does for a simulator and `devicectl` for a physical device.
@MainActor
protocol AppControl {
    func install(_ path: String) async throws -> JSONValue
    func uninstall(_ bundleID: String) async throws -> JSONValue
    func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue
    func open(_ url: String) async throws -> JSONValue
    /// Tells running apps memory is low, as Simulator's Debug > Simulate Memory Warning does.
    func memoryWarning() async throws
}

/// A simulator's apps, through `simctl`: launch restarts the app with its output captured and waits until it is in front.
@MainActor
struct SimulatorApps: AppControl {
    let device: SimulatorDevice
    let apps: DeviceApps
    let launcher: AppLauncher

    func install(_ path: String) async throws -> JSONValue { try await apps.install(path) }
    func uninstall(_ bundleID: String) async throws -> JSONValue { try await apps.uninstall(bundleID) }
    func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue { try await launcher.launch(bundleID, arguments: arguments) }
    func open(_ url: String) async throws -> JSONValue { try await launcher.open(url) }

    /// CoreSimulator tells every running app when its memory warning file is written.
    func memoryWarning() async throws {
        guard let file = device.memoryWarningFile() else {
            throw SimDriveError(.memoryWarningUnsupported, "\(device.name) reports no memory warning file.")
        }
        try Data().write(to: file)
    }
}

/// A physical device's apps, through `devicectl`. A launch restarts the app but does not wait for it to come to the
/// front, which needs accessibility.
@MainActor
final class DeviceAppControl: AppControl {
    /// Large apps take minutes to copy over the network.
    private static let installLimit: Duration = .seconds(600)
    /// How long a launched app may take to show among the device's processes.
    private static let launchLimit: Duration = .seconds(20)
    private static let launchPoll: Duration = .milliseconds(500)

    let id: String
    let tools: DeveloperTools
    let screens: Screens
    private let processes: DeviceAppProcesses
    private let logs: DeviceLogs

    init(id: String, tools: DeveloperTools, screens: Screens, logs: DeviceLogs) {
        self.id = id
        self.tools = tools
        self.screens = screens
        self.logs = logs
        processes = DeviceAppProcesses(id: id, tools: tools)
    }

    /// `devicectl device process sendMemoryWarning` fails on an iPhone (iOS 27.2.1) with "No such file or directory", though
    /// the device lists the feature.
    func memoryWarning() async throws {
        throw SimDriveError(.memoryWarningUnsupported, "A physical device refuses memory warnings from devicectl.")
    }

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

    /// Restarts the app under `devicectl --console`, which relays its stdout and stderr into the files `logs` reads and
    /// ends with the app, and returns once its new process runs. `devicectl` reports the process only when the app
    /// ends, so the process is found among the device's.
    func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue {
        let previous = try await processes.runningProcess(of: bundleID)?.pid
        let output = logs.prepareLaunch(in: StatePaths.appOutput(for: id))
        let launchedAt = Date.now
        let log = StatePaths.consoleLog(for: id)
        let console = try tools.devicectlConsole(["device", "process", "launch", "--console", "--terminate-existing",
                                                  "--environment-variables", Self.environment, "--device", id, bundleID, "--"] + arguments,
                                                 output: output, log: log)
        let deadline = ContinuousClock.now + Self.launchLimit
        var pid: Int?
        while pid == nil {
            if !console.isRunning {
                let reason = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                throw SimDriveError(.devicectl, "devicectl could not launch \(bundleID): \(reason.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            guard ContinuousClock.now < deadline else {
                throw SimDriveError(.launchNotFrontmost, "\(bundleID) did not start within \(Self.launchLimit.components.seconds) s.")
            }
            await pause(Self.launchPoll)
            pid = try await processes.runningProcess(of: bundleID).map(\.pid).flatMap { $0 == previous ? nil : $0 }
        }
        screens.forgetScreenshots()
        logs.recordLaunch(bundleID: bundleID, pid: pid, at: launchedAt, output: output)
        return ["bundleID": .string(bundleID), "pid": JSONValue(pid)]
    }

    /// Unbuffers the app's stdout, as `AppOutput.environment` does on a simulator, so lines arrive as printed.
    private static let environment: String = {
        let data = (try? JSONSerialization.data(withJSONObject: AppOutput.environment)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }()

    func open(_ url: String) async throws -> JSONValue {
        try await tools.devicectl(["device", "process", "openURL", "--device", id, url])
        screens.forgetScreenshots()
        return ["url": .string(url)]
    }
}
