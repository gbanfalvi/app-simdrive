import Foundation
import SimDriveNative
import Synchronization

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
    private static let unzip = "/usr/bin/unzip"
    /// CoreSimulator's own simctl. `xcrun simctl` reaches it through a wrapper script that adds about 0.8 s per call.
    private static let coreSimulatorSimctl = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"
    private static let developerDirectoryOverride = "SIMDRIVE_DEVELOPER_DIR"
    private static let developerDirectoryVariable = "DEVELOPER_DIR"
    /// simctl passes these variables, without the prefix, to the processes it starts.
    private static let childEnvironmentPrefix = "SIMCTL_CHILD_"
    /// How long a tool may run before it is stopped, so a guest that never answers cannot hold up the device's daemon.
    static let defaultLimit: Duration = .seconds(60)

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
        let result = try await run([xcodeSelect, "-p"], environment: environment, limit: defaultLimit, name: "xcode-select")
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

    /// Runs `simctl` and returns its result, whether or not it succeeded. `childEnvironment` reaches what it launches.
    /// Past `limit` it is stopped, and the call fails with `tool-timeout`.
    func simctlResult(_ arguments: [String], childEnvironment: [String: String] = [:],
                      limit: Duration = defaultLimit) async throws -> ToolResult {
        var environment = ProcessInfo.processInfo.environment
        environment[Self.developerDirectoryVariable] = developerDirectory
        for (name, value) in childEnvironment {
            environment[Self.childEnvironmentPrefix + name] = value
        }
        return try await Self.run(simctlCommand + arguments, environment: environment, limit: limit,
                                  name: "simctl \(arguments.first ?? "")")
    }

    /// Starts `simctl`, whose standard output then arrives line by line.
    func simctlLines(_ arguments: [String]) throws -> ToolLines {
        var environment = ProcessInfo.processInfo.environment
        environment[Self.developerDirectoryVariable] = developerDirectory
        return try ToolLines(simctlCommand + arguments, environment: environment)
    }

    /// Runs `simctl` and throws its diagnostics when it fails.
    @discardableResult
    func simctl(_ arguments: [String], childEnvironment: [String: String] = [:], limit: Duration = defaultLimit) async throws -> ToolResult {
        let result = try await simctlResult(arguments, childEnvironment: childEnvironment, limit: limit)
        guard result.succeeded else {
            throw SimDriveError(.simctl, "simctl \(arguments.first ?? "") failed: \(result.diagnostics)")
        }
        return result
    }

    /// Runs `devicectl` with `--json-output` and returns its `result`, or throws its error's description with `devicectl`.
    /// It takes about a second per call, which starting CoreDevice in its own process costs.
    @discardableResult
    func devicectl(_ arguments: [String], limit: Duration = defaultLimit) async throws -> [String: Any] {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("simdrive-devicectl-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        var environment = ProcessInfo.processInfo.environment
        environment[Self.developerDirectoryVariable] = developerDirectory
        let command = [Self.xcrun, "devicectl", "--quiet", "--json-output", output.path] + arguments
        let result = try await Self.run(command, environment: environment, limit: limit, name: "devicectl \(arguments.prefix(2).joined(separator: " "))")
        let report = (try? Data(contentsOf: output)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        guard result.succeeded else {
            let userInfo = (report?["error"] as? [String: Any])?["userInfo"] as? [String: Any]
            let description = (userInfo?["NSLocalizedDescription"] as? [String: Any])?["string"] as? String
            throw SimDriveError(.devicectl, "devicectl \(arguments.prefix(2).joined(separator: " ")) failed: \(description ?? result.diagnostics)")
        }
        return report?["result"] as? [String: Any] ?? [:]
    }

    /// Extracts the members of a zip archive that match `pattern` into `directory`.
    func unzip(_ archive: String, members pattern: String, into directory: String) async throws -> ToolResult {
        try await Self.run([Self.unzip, "-qq", "-o", archive, pattern, "-d", directory], environment: ProcessInfo.processInfo.environment,
                           limit: Self.defaultLimit, name: "unzip")
    }

    /// Runs a tool to its end, or stops it after `limit` and fails with `tool-timeout`.
    static func run(_ command: [String], environment: [String: String], limit: Duration, name: String) async throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let timeout = SimDriveError(.toolTimeout, "\(name) did not finish within \(limit.components.seconds) s and was stopped; retry, "
                                    + "or take a screenshot to see whether the simulator responds.")
        do {
            // The wait is bounded on its own, since a process the tool started can keep its pipes open after it exits.
            // Handlers collect both pipes and the exit, so a running tool blocks no thread (I18).
            return try await waitForCompletion(within: limit, timeout: timeout) { done in
                let collection = ToolOutputCollection(done)
                collection.read(output, into: \.output)
                collection.read(errors, into: \.errors)
                process.terminationHandler = { collection.exited(with: $0.terminationStatus) }
                do { try process.run() } catch { done(.failure(error)) }
            }.get()
        } catch let error as SimDriveError where error == timeout {
            if process.isRunning { process.terminate() }
            throw error
        }
    }
}

/// A tool's two pipes and its exit, gathered from their handlers' threads, which reports once all three have ended.
private final class ToolOutputCollection: Sendable {
    struct State {
        var output = Data()
        var errors = Data()
        var openPipes = 2
        var status: Int32?
        var done: (@Sendable (Result<ToolResult, any Error>) -> Void)?
    }

    private let state: Mutex<State>

    init(_ done: @escaping @Sendable (Result<ToolResult, any Error>) -> Void) {
        state = Mutex(State(done: done))
    }

    /// Drains `pipe` as data arrives, so it can never fill and block the tool.
    func read(_ pipe: Pipe, into keyPath: WritableKeyPath<State, Data> & Sendable) {
        pipe.fileHandleForReading.readabilityHandler = { [self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                finishIfDone { $0.openPipes -= 1 }
            } else {
                state.withLock { $0[keyPath: keyPath].append(data) }
            }
        }
    }

    func exited(with status: Int32) {
        finishIfDone { $0.status = status }
    }

    private func finishIfDone(_ change: (inout State) -> Void) {
        let finished: (@Sendable (Result<ToolResult, any Error>) -> Void, ToolResult)? = state.withLock { state in
            change(&state)
            guard state.openPipes == 0, let status = state.status, let done = state.done else { return nil }
            state.done = nil
            return (done, ToolResult(status: status, standardOutput: String(decoding: state.output, as: UTF8.self),
                                     standardError: String(decoding: state.errors, as: UTF8.self)))
        }
        finished.map { $0.0(.success($0.1)) }
    }
}

/// A running tool's standard output, line by line, until the tool exits or is stopped.
final class ToolLines: @unchecked Sendable {
    private static let newline = UInt8(ascii: "\n")

    let lines: AsyncStream<String>
    private let process = Process()

    fileprivate init(_ command: [String], environment: [String: String]) throws {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        self.lines = lines
        process.executableURL = URL(fileURLWithPath: command[0])
        process.arguments = Array(command.dropFirst())
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        // The handler runs on one queue at a time, so it alone touches `pending`.
        nonisolated(unsafe) var pending = Data()
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                if !pending.isEmpty { continuation.yield(String(decoding: pending, as: UTF8.self)) }
                continuation.finish()
                return
            }
            pending.append(data)
            while let end = pending.firstIndex(of: Self.newline) {
                continuation.yield(String(decoding: pending[pending.startIndex..<end], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...end)
            }
        }
        try process.run()
    }

    /// Interrupts rather than terminates, since `simctl spawn` passes only an interrupt on to the guest's process.
    func stop() {
        if process.isRunning { process.interrupt() }
    }

    deinit { stop() }
}
