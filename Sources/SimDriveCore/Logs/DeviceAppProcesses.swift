import Foundation
import SimDriveNative

/// A physical device's apps, processes and crash reports, through `devicectl`, for `logs`, `launch` and memory warnings.
@MainActor
struct DeviceAppProcesses {
    private static let modifiedFormat = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let appExtension = ".app"

    let id: String
    let tools: DeveloperTools

    /// The app's bundle on the device, as a `file:` URL ending in `/`; fails with `app-not-installed`.
    func bundleURL(of bundleID: String) async throws -> String {
        let result = try await tools.devicectl(["device", "info", "apps", "--device", id, "--bundle-id", bundleID])
        guard let app = (result["apps"] as? [[String: Any]])?.first, let url = app["url"] as? String else {
            throw SimDriveError(.appNotInstalled, "\(bundleID) is not installed.")
        }
        return url.hasSuffix("/") ? url : url + "/"
    }

    /// The app's running process, whose executable lies directly in its bundle; nil when it is not running.
    func runningProcess(of bundleID: String) async throws -> (pid: Int, executable: String)? {
        let bundle = try await bundleURL(of: bundleID)
        let result = try await tools.devicectl(["device", "info", "processes", "--device", id])
        for process in result["runningProcesses"] as? [[String: Any]] ?? [] {
            guard let executable = process["executable"] as? String, let pid = process["processIdentifier"] as? Int,
                  executable.hasPrefix(bundle), !executable.dropFirst(bundle.count).contains("/") else { continue }
            return (pid, String(executable.dropFirst(bundle.count)))
        }
        return nil
    }

    /// The app's executable name: its running process's, or else its bundle's name, which Xcode gives the executable.
    func executable(of bundleID: String) async throws -> String {
        if let running = try await runningProcess(of: bundleID) { return running.executable }
        let bundle = try await bundleURL(of: bundleID).dropLast()
        let name = bundle.split(separator: "/").last.map(String.init) ?? bundleID
        return name.hasSuffix(Self.appExtension) ? String(name.dropLast(Self.appExtension.count)) : name
    }

    /// The device's crash reports written after `writtenAfter`, copied to `directory`.
    func crashReports(writtenAfter: Date, into directory: URL) async throws -> [CrashReportFile] {
        let listing = try await tools.devicectl(["device", "info", "files", "--device", id, "--domain-type", "systemCrashLogs"])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var copied: [CrashReportFile] = []
        for file in listing["files"] as? [[String: Any]] ?? [] {
            guard let path = file["relativePath"] as? String, path.hasSuffix("." + CrashReports.reportExtension),
                  let stamp = (file["metadata"] as? [String: Any])?["lastModDate"] as? String,
                  let modified = try? Self.modifiedFormat.parse(stamp), modified > writtenAfter else { continue }
            let local = directory.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
            try? FileManager.default.removeItem(at: local)
            try await tools.devicectl(["device", "copy", "from", "--device", id, "--domain-type", "systemCrashLogs",
                                       "--source", path, "--destination", local.path])
            copied.append(CrashReportFile(url: local, modified: modified))
        }
        return copied
    }
}
