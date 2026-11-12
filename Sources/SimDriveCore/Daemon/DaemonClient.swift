import Darwin
import Foundation
import SimDriveNative

/// Sends a command to the device's daemon, starting one when none runs.
enum DaemonClient {
    private static let startLimit: Duration = .seconds(30)
    private static let exitLimit: Duration = .seconds(5)
    private static let poll: Duration = .milliseconds(100)
    private static let serveCommand = "serve"
    private static let stopCommand = "stop"
    private static let rootDirectory = "/"
    private static let logMode: mode_t = 0o600

    static func send(udid: String, arguments: [String], workingDirectory: String,
                     tools: DeveloperTools) async throws -> CommandResponse {
        let request = try request(arguments, workingDirectory: workingDirectory, tools: tools)
        let response = try exchange(request, on: try await connection(udid: udid, tools: tools))
        guard response.code == ErrorCode.staleDaemon.rawValue else { return response }
        try await waitForExit(udid: udid)
        return try exchange(request, on: try await connection(udid: udid, tools: tools))
    }

    /// Stops the device's daemon, if one runs.
    static func stop(udid: String, tools: DeveloperTools) async throws -> CommandResponse {
        guard let socketDescriptor = UnixSocket.connect(to: StatePaths.socket(for: udid).path) else {
            return .success(["stopped": false])
        }
        _ = try exchange(try request([stopCommand], workingDirectory: rootDirectory, tools: tools), on: socketDescriptor)
        try await waitForExit(udid: udid)
        return .success(["stopped": true])
    }

    /// A daemon from another build or developer directory refuses the request and exits.
    private static func request(_ arguments: [String], workingDirectory: String, tools: DeveloperTools) throws -> Data {
        try JSONEncoder.line.encode(DaemonRequest(arguments: arguments, workingDirectory: workingDirectory, build: BuildStamp.current,
                                                  developerDirectory: tools.developerDirectory))
    }

    private static func exchange(_ request: Data, on socketDescriptor: Int32) throws -> CommandResponse {
        defer { close(socketDescriptor) }
        try UnixSocket.writeMessage(request, to: socketDescriptor)
        let reply = try UnixSocket.readMessage(from: socketDescriptor)
        guard !reply.isEmpty else {
            throw SimDriveError(.daemonEnded, "The daemon ended without replying; see its log in \(StatePaths.directory.path).")
        }
        return try JSONDecoder().decode(CommandResponse.self, from: reply)
    }

    private static func connection(udid: String, tools: DeveloperTools) async throws -> Int32 {
        let path = StatePaths.socket(for: udid).path
        if let socketDescriptor = UnixSocket.connect(to: path) { return socketDescriptor }
        try StatePaths.prepare()
        try spawnDaemon(udid: udid, tools: tools)
        let deadline = ContinuousClock.now + startLimit
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: poll)
            if let socketDescriptor = UnixSocket.connect(to: path) { return socketDescriptor }
        }
        throw SimDriveError(.daemonStart, "The daemon did not start; see \(StatePaths.log(for: udid).path).")
    }

    private static func waitForExit(udid: String) async throws {
        let path = StatePaths.socket(for: udid).path
        let deadline = ContinuousClock.now + exitLimit
        while FileManager.default.fileExists(atPath: path), ContinuousClock.now < deadline {
            try await Task.sleep(for: poll)
        }
    }

    /// Starts `simdrive <udid> serve` in its own session, so it outlives this process and its terminal.
    private static func spawnDaemon(udid: String, tools: DeveloperTools) throws {
        guard let executable = Bundle.main.executablePath else {
            throw SimDriveError(.daemonStart, "The simdrive executable could not be located.")
        }
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        posix_spawnattr_init(&attributes)
        posix_spawn_file_actions_init(&actions)
        defer {
            posix_spawnattr_destroy(&attributes)
            posix_spawn_file_actions_destroy(&actions)
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, StatePaths.log(for: udid).path,
                                         O_WRONLY | O_CREAT | O_APPEND, logMode)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        let arguments = [executable, udid, serveCommand].map { strdup($0) } + [nil]
        let environment = tools.pinnedEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (arguments + environment).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, arguments, environment)
        guard status == 0 else {
            throw SimDriveError(.daemonStart, "Could not start the daemon: \(String(cString: strerror(status)))")
        }
    }
}
