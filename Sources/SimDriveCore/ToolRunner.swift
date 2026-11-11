import Foundation

/// A finished command's status and output.
package struct ToolResult: Sendable {
    package let status: Int32
    package let output: String
    package let errorOutput: String

    package var succeeded: Bool { status == 0 }
    /// Standard error, or standard output when that is empty, for error messages.
    package var diagnostics: String {
        let text = errorOutput.isEmpty ? output : errorOutput
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs Xcode's command-line tools against one developer directory.
package struct ToolRunner: Sendable {
    private static let xcrun = "/usr/bin/xcrun"
    private static let xcodeSelect = "/usr/bin/xcode-select"
    private static let developerDirectoryOverride = "SIMDRIVE_DEVELOPER_DIR"
    private static let developerDirectoryVariable = "DEVELOPER_DIR"

    package let developerDirectory: String

    package init(developerDirectory: String) {
        self.developerDirectory = developerDirectory
    }

    /// `SIMDRIVE_DEVELOPER_DIR`, then `DEVELOPER_DIR`, then `xcode-select -p`.
    package static func resolveDeveloperDirectory() async throws -> String {
        let environment = ProcessInfo.processInfo.environment
        if let directory = environment[developerDirectoryOverride] ?? environment[developerDirectoryVariable], !directory.isEmpty {
            return directory
        }
        let result = try await run(xcodeSelect, ["-p"], environment: environment)
        let directory = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !directory.isEmpty else {
            throw SimDriveError("developer-directory", "xcode-select has no developer directory: \(result.diagnostics)")
        }
        return directory
    }

    /// This process's environment, with this developer directory taking precedence for a child `simdrive`.
    package var pinnedEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[Self.developerDirectoryOverride] = developerDirectory
        return environment
    }

    package func simctl(_ arguments: [String]) async throws -> ToolResult {
        var environment = ProcessInfo.processInfo.environment
        environment[Self.developerDirectoryVariable] = developerDirectory
        return try await Self.run(Self.xcrun, ["simctl"] + arguments, environment: environment)
    }

    /// Runs `simctl` and throws its diagnostics when it fails.
    @discardableResult
    package func checkedSimctl(_ arguments: [String]) async throws -> ToolResult {
        let result = try await simctl(arguments)
        guard result.succeeded else {
            throw SimDriveError("simctl", "simctl \(arguments.first ?? "") failed: \(result.diagnostics)")
        }
        return result
    }

    private static func run(_ executable: String, _ arguments: [String], environment: [String: String]) async throws -> ToolResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try runSynchronously(executable, arguments, environment: environment) })
            }
        }
    }

    private static func runSynchronously(_ executable: String, _ arguments: [String], environment: [String: String]) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
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
        return ToolResult(status: process.terminationStatus, output: String(decoding: outputData, as: UTF8.self),
                          errorOutput: String(decoding: errorData, as: UTF8.self))
    }
}

/// A failure of a command, named by a stable identifier.
package struct SimDriveError: LocalizedError, Equatable, Sendable {
    package let identifier: String
    package let message: String

    package init(_ identifier: String, _ message: String) {
        self.identifier = identifier
        self.message = message
    }

    package var errorDescription: String? { message }
}
