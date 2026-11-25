import Foundation
import SimDriveNative

/// Brings apps to the front: `launch`, which restarts an app with its output captured and waits until it is in front,
/// and `openurl`. Both change what is on screen, so both forget the screens' records.
@MainActor
struct AppLauncher {
    /// How long an app may take to come to the front after `simctl launch`, which returns seconds before it does. A
    /// freshly booted, busy simulator takes tens of seconds.
    static let launchLimit: Duration = .seconds(30)

    let udid: String
    let device: SimulatorDevice
    let tools: DeveloperTools
    let settings: DeviceSettings
    let logs: DeviceLogs
    let screens: Screens
    let accessibility: DeviceAccessibility

    func launch(_ bundleID: String, arguments: [String]) async throws -> JSONValue {
        try await settings.enableApplicationAccessibility()
        let output = logs.prepareLaunch(dataDirectory: device.dataDirectory)
        let launchedAt = Date.now
        // Restarts a running app, so it starts from its launch screen with these arguments.
        let result = try await tools.simctl(["launch", "--terminate-running-process"] + output.launchOptions + [udid, bundleID] + arguments,
                                            childEnvironment: AppOutput.environment)
        screens.forgetScreenshots()
        let pid = Self.pid(fromLaunchOutput: result.standardOutput)
        logs.recordLaunch(bundleID: bundleID, pid: pid, at: launchedAt, output: output)
        if let pid, !(await accessibility.becomesFrontmost(pid, within: Self.launchLimit)) {
            throw SimDriveError(.launchNotFrontmost, "\(bundleID) launched as pid \(pid) but did not come to the front within "
                                + "\(Self.launchLimit.components.seconds) s; take a screenshot to see what is in front.")
        }
        return ["bundleID": .string(bundleID), "pid": JSONValue(pid)]
    }

    func open(_ url: String) async throws -> JSONValue {
        try await tools.simctl(["openurl", udid, url])
        screens.forgetScreenshots()
        return ["url": .string(url)]
    }

    /// `simctl launch` prints `<bundle-id>: <pid>`; nil when it printed something else.
    nonisolated static func pid(fromLaunchOutput output: String) -> Int? {
        output.split(separator: ":").last.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
}
