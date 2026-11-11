import Foundation
import SimDriveNative

/// A finished tool's exit status and output.
struct ToolResult: Sendable {
    let status: Int32
    let standardOutput: String
    let standardError: String

    var succeeded: Bool { status == 0 }
    /// Standard error, or standard output when that is empty, for error messages.
    var diagnostics: String {
        let text = standardError.isEmpty ? standardOutput : standardError
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs Xcode's command-line tools against one developer directory.
struct DeveloperTools: Sendable {
    private static let xcrun = "/usr/bin/xcrun"
    private static let xcodeSelect = "/usr/bin/xcode-select"
    /// CoreSimulator's own simctl. `xcrun simctl` reaches it through a wrapper script that adds about 0.8 s per call.
    private static let coreSimulatorSimctl = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
    private static let developerDirectoryOverride = "SIMDRIVE_DEVELOPER_DIR"
    private static let developerDirectoryVariable = "DEVELOPER_DIR"

    let developerDirectory: String
    private let simctlCommand: [String]

    init(developerDirectory: String) {
        self.developerDirectory = developerDirectory
        simctlCommand = FileManager.default.isExecutableFile(atPath: Self.coreSimulatorSimctl)
            ? [Self.coreSimulatorSimctl]
            : [Self.xcrun, "simctl"]
    }

    /// `SIMDRIVE_DEVELOPER_DIR`, then `DEVELOPER_DIR`, then `xcode-select -p`.
    static func resolveDeveloperDirectory() async throws -> String {
        let environment = ProcessInfo.processInfo.environment
        if let directory = environment[developerDirectoryOverride] ?? environment[developerDirectoryVariable], !directory.isEmpty {
            return directory
        }
        let result = try await run([xcodeSelect, "-p"], environment: environment)
        let directory = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !directory.isEmpty else {
            throw SimDriveError(.developerDirectory, "xcode-select has no developer directory: \(result.diagnostics)")
        }
        return directory
    }

    /// This process's environment, with this developer directory taking precedence for a child `simdrive`.
    var pinnedEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[Self.developerDirectoryOverride] = developerDirectory
        return environment
    }

    /// Runs `simctl` and returns its result, whether or not it succeeded.
    func simctlResult(_ arguments: [String]) async throws -> ToolResult {
        var environment = ProcessInfo.processInfo.environment
        environment[Self.developerDirectoryVariable] = developerDirectory
        return try await Self.run(simctlCommand + arguments, environment: environment)
    }

    /// Runs `simctl` and throws its diagnostics when it fails.
    @discardableResult
    func simctl(_ arguments: [String]) async throws -> ToolResult {
        let result = try await simctlResult(arguments)
        guard result.succeeded else {
            throw SimDriveError(.simctl, "simctl \(arguments.first ?? "") failed: \(result.diagnostics)")
        }
        return result
    }

    private static func run(_ command: [String], environment: [String: String]) async throws -> ToolResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runSynchronously(command, environment: environment) })
            }
        }
    }

    private static func runSynchronously(_ command: [String], environment: [String: String]) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Both pipes drain while the process runs, so neither can fill and block it.
        nonisolated(unsafe) var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus, standardOutput: String(decoding: outputData, as: UTF8.self),
                          standardError: String(decoding: errorData, as: UTF8.self))
    }
}
