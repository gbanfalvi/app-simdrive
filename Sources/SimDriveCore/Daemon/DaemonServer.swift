import Darwin
import Foundation
import SimDriveNative

/// Serves one device's commands over its socket, one at a time, until it is idle for ten minutes or told to stop.
@MainActor
final class DaemonServer {
    private static let idleLimit: Duration = .seconds(600)
    private static let idleCheck: Duration = .seconds(5)
    /// How long closing the session may take at shutdown, since a guest that stopped answering cannot be released.
    private static let closeLimit: Duration = .seconds(3)

    private let udid: String
    private let tools: DeveloperTools
    private var session: DeviceSession?
    private var lastActivity = ContinuousClock.now
    private var activeRequests = 0
    private var pending: Task<Void, Never>?
    private var listener: Int32 = -1
    private var signalSources: [any DispatchSourceSignal] = []
    /// Set once shutdown starts; the idle loop, a `stop` request and a signal all await this one shutdown.
    private var stopping: Task<Void, Never>?

    init(udid: String, tools: DeveloperTools) {
        self.udid = udid
        self.tools = tools
    }

    func run() async throws {
        try StatePaths.prepare()
        let listener = try UnixSocket.listen(at: StatePaths.socket(for: udid).path)
        self.listener = listener
        installSignalHandlers()
        log("listening for \(udid) with \(tools.developerDirectory)")
        // accept() blocks, so it waits on a thread of its own and hands each request to the main actor.
        Thread.detachNewThread { [self] in Self.acceptConnections(on: listener, server: self) }
        while stopping == nil {
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
        // `stop` skips the queue, so a request stuck on the guest cannot keep the daemon from stopping.
        if Self.isStop(message) {
            log("stopping on request")
            return ((try? JSONEncoder.line.encode(CommandResponse.success(["stopped": true]))) ?? Data(), true)
        }
        activeRequests += 1
        lastActivity = .now
        defer {
            activeRequests -= 1
            lastActivity = .now
        }
        // Each request waits for the one before it, since the main actor interleaves their awaits otherwise.
        let previous = pending
        let task = Task { @MainActor in
            await previous?.value
            return await self.handle(message)
        }
        pending = Task { _ = await task.value }
        let (response, stops) = await task.value
        return ((try? JSONEncoder.line.encode(response)) ?? Data(), stops)
    }

    private func handle(_ message: Data?) async -> (CommandResponse, Bool) {
        guard let message, let request = try? JSONDecoder().decode(DaemonRequest.self, from: message) else {
            return (.failure(SimDriveError(.badRequest, "The daemon could not read the request.")), false)
        }
        guard request.build == BuildStamp.current, request.developerDirectory == tools.developerDirectory else {
            log("replaced by a client with another build or developer directory")
            return (.failure(SimDriveError(.staleDaemon, "The daemon runs another build or developer directory.")), true)
        }
        do {
            let command = try CommandParser.parse(request.arguments)
            let session = try await openSession()
            return (.success(try await session.execute(command, workingDirectory: request.workingDirectory)), false)
        } catch {
            log("\(request.arguments.joined(separator: " ")): \(error.localizedDescription)")
            let code = (error as? SimDriveError)?.code
            // A guest connection stays dead once it ends, so the next command opens new ones.
            if code == .guestConnection { await session?.releaseInputs() }
            // A shut-down device has nothing to serve; the next command starts a daemon once it boots.
            return (.failure(error), code == .notBooted)
        }
    }

    /// A daemon of any build stops when asked, so a client never needs to match its build to stop it.
    private static func isStop(_ message: Data?) -> Bool {
        guard let message, let request = try? JSONDecoder().decode(DaemonRequest.self, from: message) else { return false }
        return (try? CommandParser.parse(request.arguments)) == .stop
    }

    private func openSession() async throws -> DeviceSession {
        if let session {
            if session.isCurrent { return session }
            log("the device rebooted or shut down; reopening")
            self.session = nil
            await session.close()
        }
        let opened = try await DeviceSession.open(udid: udid, tools: tools)
        session = opened
        return opened
    }

    private func shutdown() async {
        let stopping = self.stopping ?? Task { await closeAll() }
        self.stopping = stopping
        await stopping.value
    }

    private func closeAll() async {
        if let session {
            do {
                try await waitForCompletion(within: Self.closeLimit, timeout: SimDriveError(.daemonSocket, "closing timed out")) { done in
                    Task { @MainActor in
                        await session.close()
                        done(())
                    }
                }
            } catch {
                log("the session did not close within \(Self.closeLimit.components.seconds) s; exiting without it")
            }
        }
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        unlink(StatePaths.socket(for: udid).path)
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
