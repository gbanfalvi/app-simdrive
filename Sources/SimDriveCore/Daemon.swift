import Darwin
import Foundation
import SimDriveNative

/// Per-user files: each device's socket, log, screenshot records and calibration image.
package enum DaemonPaths {
    /// Unix socket paths are limited to 104 bytes, which `$TMPDIR` plus a UDID can exceed.
    package static let directory = URL(fileURLWithPath: "/tmp/simdrive-\(getuid())", isDirectory: true)
    private static let privateDirectoryMode = 0o700

    package static func socket(for udid: String) -> URL { directory.appendingPathComponent("\(udid).sock") }
    package static func log(for udid: String) -> URL { directory.appendingPathComponent("\(udid).log") }
    package static func screens(for udid: String) -> URL { directory.appendingPathComponent("\(udid).screens.json") }
    package static func calibration(for udid: String) -> URL { directory.appendingPathComponent("\(udid).calibration.png") }

    package static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: privateDirectoryMode])
    }
}

/// Identifies the running executable, so a client replaces a daemon from an older build.
package enum BuildStamp {
    package static let current: String = {
        guard let path = Bundle.main.executablePath,
              let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date else {
            return "unknown"
        }
        return String(date.timeIntervalSince1970)
    }()
}

package struct DaemonRequest: Codable, Sendable {
    package let arguments: [String]
    package let workingDirectory: String
    package let build: String
    package let developerDirectory: String
}

package struct DaemonResponse: Codable, Sendable {
    static let staleCode = "stale-daemon"

    package let ok: Bool
    package let result: JSONValue?
    package let error: String?
    package let code: String?

    package static func success(_ result: JSONValue) -> DaemonResponse {
        DaemonResponse(ok: true, result: result, error: nil, code: nil)
    }

    package static func failure(_ error: any Error) -> DaemonResponse {
        let code = (error as? SimDriveError)?.identifier ?? (error as? NativeError)?.identifier ?? (error is UsageError ? "usage" : nil)
        return DaemonResponse(ok: false, result: nil, error: error.localizedDescription, code: code)
    }
}

/// Serves one device's commands over its socket, one at a time, until it is idle for ten minutes or told to stop.
@MainActor
package final class DaemonServer {
    private static let idleLimit: Duration = .seconds(600)
    private static let idleCheck: Duration = .seconds(5)
    private static let guestConnectionFailure = "guest-hid-connection"

    private let udid: String
    private let tools: ToolRunner
    private var session: DeviceSession?
    private var lastActivity = ContinuousClock.now
    private var activeRequests = 0
    private var pending: Task<Void, Never>?
    private var listener: Int32 = -1
    private var signalSources: [any DispatchSourceSignal] = []
    private var isStopping = false

    package init(udid: String, tools: ToolRunner) {
        self.udid = udid
        self.tools = tools
    }

    package func run() async throws {
        try DaemonPaths.prepare()
        let listener = try UnixSocket.listen(at: DaemonPaths.socket(for: udid).path)
        self.listener = listener
        installSignalHandlers()
        log("listening for \(udid) with \(tools.developerDirectory)")
        Thread.detachNewThread { [self] in Self.acceptConnections(on: listener, server: self) }
        while !isStopping {
            try? await Task.sleep(for: Self.idleCheck)
            if activeRequests == 0, ContinuousClock.now - lastActivity > Self.idleLimit {
                log("idle; exiting")
                break
            }
        }
        await shutdown()
    }

    private nonisolated static func acceptConnections(on listener: Int32, server: DaemonServer) {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                if errno == EINTR { continue }
                return
            }
            let message = try? UnixSocket.readMessage(from: client)
            Task { @MainActor in
                let (reply, stops) = await server.respond(to: message)
                try? UnixSocket.writeMessage(reply, to: client)
                close(client)
                if stops {
                    await server.shutdown()
                    exit(EXIT_SUCCESS)
                }
            }
        }
    }

    private func respond(to message: Data?) async -> (Data, Bool) {
        activeRequests += 1
        lastActivity = .now
        defer {
            activeRequests -= 1
            lastActivity = .now
        }
        let previous = pending
        let task = Task { @MainActor in
            await previous?.value
            return await self.handle(message)
        }
        pending = Task { _ = await task.value }
        let (response, stops) = await task.value
        return ((try? JSONEncoder.line.encode(response)) ?? Data(), stops)
    }

    private func handle(_ message: Data?) async -> (DaemonResponse, Bool) {
        guard let message, let request = try? JSONDecoder().decode(DaemonRequest.self, from: message) else {
            return (.failure(SimDriveError("bad-request", "The daemon could not read the request.")), false)
        }
        guard request.build == BuildStamp.current, request.developerDirectory == tools.developerDirectory else {
            log("replaced by a client with another build or developer directory")
            let reason = "The daemon runs another build or developer directory."
            return (DaemonResponse(ok: false, result: nil, error: reason, code: DaemonResponse.staleCode), true)
        }
        do {
            let command = try CommandParser.parse(request.arguments)
            if command == .stop { return (.success(["stopped": true]), true) }
            let session = try await openSession()
            return (.success(try await session.execute(command, workingDirectory: request.workingDirectory)), false)
        } catch {
            log("\(request.arguments.joined(separator: " ")): \(error.localizedDescription)")
            if (error as? NativeError)?.identifier == Self.guestConnectionFailure { await session?.releaseInputs() }
            return (.failure(error), false)
        }
    }

    private func openSession() async throws -> DeviceSession {
        if let session { return session }
        let opened = try await DeviceSession.open(udid: udid, tools: tools)
        session = opened
        return opened
    }

    private func shutdown() async {
        guard listener >= 0 else { return }
        isStopping = true
        await session?.close()
        close(listener)
        listener = -1
        unlink(DaemonPaths.socket(for: udid).path)
    }

    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in
                    await self?.shutdown()
                    exit(EXIT_SUCCESS)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("\(Date.now.ISO8601Format()) \(message)\n".utf8))
    }
}

/// Sends a command to the device's daemon, starting one when none runs.
package enum DaemonClient {
    private static let startLimit: Duration = .seconds(30)
    private static let exitLimit: Duration = .seconds(5)
    private static let poll: Duration = .milliseconds(100)
    private static let serveCommand = "serve"
    private static let logMode: mode_t = 0o600

    package static func send(udid: String, arguments: [String], workingDirectory: String,
                             tools: ToolRunner) async throws -> DaemonResponse {
        let request = try JSONEncoder.line.encode(DaemonRequest(arguments: arguments, workingDirectory: workingDirectory,
                                                                build: BuildStamp.current,
                                                                developerDirectory: tools.developerDirectory))
        let response = try exchange(request, on: try await connection(udid: udid, tools: tools))
        guard response.code == DaemonResponse.staleCode else { return response }
        try await waitForExit(udid: udid)
        return try exchange(request, on: try await connection(udid: udid, tools: tools))
    }

    /// Stops the device's daemon, if one runs.
    package static func stop(udid: String, tools: ToolRunner) async throws -> DaemonResponse {
        guard let socketDescriptor = UnixSocket.connect(to: DaemonPaths.socket(for: udid).path) else {
            return .success(["stopped": false])
        }
        let request = try JSONEncoder.line.encode(DaemonRequest(arguments: ["stop"], workingDirectory: "/", build: BuildStamp.current,
                                                                developerDirectory: tools.developerDirectory))
        _ = try exchange(request, on: socketDescriptor)
        try await waitForExit(udid: udid)
        return .success(["stopped": true])
    }

    private static func exchange(_ request: Data, on socketDescriptor: Int32) throws -> DaemonResponse {
        defer { close(socketDescriptor) }
        try UnixSocket.writeMessage(request, to: socketDescriptor)
        let reply = try UnixSocket.readMessage(from: socketDescriptor)
        guard !reply.isEmpty else {
            throw SimDriveError("daemon-ended", "The daemon ended without replying; see its log in \(DaemonPaths.directory.path).")
        }
        return try JSONDecoder().decode(DaemonResponse.self, from: reply)
    }

    private static func connection(udid: String, tools: ToolRunner) async throws -> Int32 {
        let path = DaemonPaths.socket(for: udid).path
        if let socketDescriptor = UnixSocket.connect(to: path) { return socketDescriptor }
        try DaemonPaths.prepare()
        try spawnDaemon(udid: udid, tools: tools)
        let deadline = ContinuousClock.now + startLimit
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: poll)
            if let socketDescriptor = UnixSocket.connect(to: path) { return socketDescriptor }
        }
        throw SimDriveError("daemon-start", "The daemon did not start; see \(DaemonPaths.log(for: udid).path).")
    }

    private static func waitForExit(udid: String) async throws {
        let path = DaemonPaths.socket(for: udid).path
        let deadline = ContinuousClock.now + exitLimit
        while FileManager.default.fileExists(atPath: path), ContinuousClock.now < deadline {
            try await Task.sleep(for: poll)
        }
    }

    /// Starts `simdrive <udid> serve` in its own session, so it outlives this process and its terminal.
    private static func spawnDaemon(udid: String, tools: ToolRunner) throws {
        guard let executable = Bundle.main.executablePath else {
            throw SimDriveError("daemon-start", "The simdrive executable could not be located.")
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
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, DaemonPaths.log(for: udid).path,
                                         O_WRONLY | O_CREAT | O_APPEND, logMode)
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)
        let arguments = [executable, udid, serveCommand].map { strdup($0) } + [nil]
        let environment = tools.pinnedEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (arguments + environment).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, executable, &actions, &attributes, arguments, environment)
        guard status == 0 else {
            throw SimDriveError("daemon-start", "Could not start the daemon: \(String(cString: strerror(status)))")
        }
    }
}
