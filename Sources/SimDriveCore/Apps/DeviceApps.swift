import Foundation
import SimDriveNative

/// Installs and removes a device's apps through `simctl`, which takes an `.app` or an `.ipa`.
struct DeviceApps {
    private static let appExtension = "app"
    private static let archiveExtension = "ipa"
    private static let payloadDirectory = "Payload"
    private static let infoPlist = "Info.plist"
    private static let bundleIdentifierKey = "CFBundleIdentifier"

    private let udid: String
    private let tools: DeveloperTools

    init(udid: String, tools: DeveloperTools) {
        self.udid = udid
        self.tools = tools
    }

    func install(_ path: String) async throws -> JSONValue {
        let bundleID = try await bundleIdentifier(of: URL(fileURLWithPath: path))
        try await tools.simctl(["install", udid, path])
        return ["bundleID": .string(bundleID)]
    }

    func uninstall(_ bundleID: String) async throws -> JSONValue {
        // simctl succeeds without removing anything when the app is missing.
        guard try await tools.simctlResult(["get_app_container", udid, bundleID]).succeeded else {
            throw SimDriveError(.appNotInstalled, "\(bundleID) is not installed.")
        }
        try await tools.simctl(["uninstall", udid, bundleID])
        return ["bundleID": .string(bundleID)]
    }

    private func bundleIdentifier(of package: URL) async throws -> String {
        guard FileManager.default.fileExists(atPath: package.path) else {
            throw SimDriveError(.appInvalid, "\(package.path) does not exist.")
        }
        switch package.pathExtension.lowercased() {
        case Self.appExtension:
            return try Self.bundleIdentifier(ofApp: package)
        case Self.archiveExtension:
            return try await bundleIdentifier(ofArchive: package)
        default:
            throw SimDriveError(.appInvalid, "\(package.path) is neither an .app nor an .ipa.")
        }
    }

    private func bundleIdentifier(ofArchive archive: URL) async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pattern = "\(Self.payloadDirectory)/*.\(Self.appExtension)/\(Self.infoPlist)"
        let result = try await tools.unzip(archive.path, members: pattern, into: directory.path)
        let payload = directory.appendingPathComponent(Self.payloadDirectory)
        let apps = (try? FileManager.default.contentsOfDirectory(at: payload, includingPropertiesForKeys: nil)) ?? []
        guard result.succeeded, let app = apps.first(where: { $0.pathExtension == Self.appExtension }) else {
            throw SimDriveError(.appInvalid, "\(archive.path) holds no \(pattern): \(result.diagnostics)")
        }
        return try Self.bundleIdentifier(ofApp: app)
    }

    private static func bundleIdentifier(ofApp app: URL) throws -> String {
        let info = NSDictionary(contentsOf: app.appendingPathComponent(infoPlist))
        guard let bundleID = info?[bundleIdentifierKey] as? String else {
            throw SimDriveError(.appInvalid, "\(app.path) has no Info.plist with a \(bundleIdentifierKey).")
        }
        return bundleID
    }
}
