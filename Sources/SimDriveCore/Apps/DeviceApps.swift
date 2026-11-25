import Foundation
import SimDriveNative

/// Installs and removes a device's apps through `simctl`, which takes an `.app` or an `.ipa`.
struct DeviceApps {
    private static let appExtension = "app"
    private static let archiveExtension = "ipa"
    private static let payloadDirectory = "Payload"
    private static let infoPlist = "Info.plist"
    private static let bundleIdentifierKey = "CFBundleIdentifier"
    /// Large apps take minutes to copy and register.
    private static let installLimit: Duration = .seconds(600)
    /// The first push after a boot took 52 s on an iPhone 17, iOS 27.2, before the guest delivered it; later ones 0.3 s.
    private static let pushLimit: Duration = .seconds(120)

    private let udid: String
    private let tools: DeveloperTools

    init(udid: String, tools: DeveloperTools) {
        self.udid = udid
        self.tools = tools
    }

    func install(_ path: String) async throws -> JSONValue {
        let bundleID = try await bundleIdentifier(of: URL(fileURLWithPath: path))
        try await tools.simctl(["install", udid, path], limit: Self.installLimit)
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

    /// `simctl push` checks the payload: a JSON object with an `aps` key, 4096 bytes at most.
    func push(_ payload: PushPayload, to bundleID: String, workingDirectory: String) async throws -> JSONValue {
        switch payload {
        case .file(let path):
            let url = URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: workingDirectory, isDirectory: true))
            try await tools.simctl(["push", udid, bundleID, url.path], limit: Self.pushLimit)
        case .json(let text):
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("simdrive-push-\(UUID().uuidString).json")
            try Data(text.utf8).write(to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            try await tools.simctl(["push", udid, bundleID, file.path], limit: Self.pushLimit)
        }
        return ["bundleID": .string(bundleID)]
    }

    /// Changing some services terminates the app if it runs, as `simctl privacy` warns.
    func privacy(_ action: PrivacyAction, service: String, bundleID: String?) async throws -> JSONValue {
        try await tools.simctl(["privacy", udid, action.rawValue, service] + (bundleID.map { [$0] } ?? []))
        return ["action": .string(action.rawValue), "service": .string(service), "bundleID": JSONValue(bundleID)]
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
