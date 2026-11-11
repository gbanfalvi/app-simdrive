import Darwin
import Foundation
import SimDriveNative

/// Serves one device's commands over its socket, one at a time, until it is idle for ten minutes or told to stop.
@MainActor
final class DaemonServer {
    private static let idleLimit: Duration = .seconds(600)
    private static let idleCheck: Duration = .seconds(5)

    private let udid: String
    private let tools: DeveloperTools
    private var session: DeviceSession?
    private var lastActivity = ContinuousClock.now
    private var activeRequests = 0
    private var pending: Task<Void, Never>?
    private var listener: Int32 = -1
    private var signalSources: [any DispatchSourceSignal] = []
    private var isStopping = false

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
            if command == .stop { return (.success(["stopped": true]), true) }
            let session = try await openSession()
            return (.success(try await session.execute(command, workingDirectory: request.workingDirectory)), false)
        } catch {
            log("\(request.arguments.joined(separator: " ")): \(error.localizedDescription)")
            // A guest connection stays dead once it ends, so the next command opens new ones.
            if (error as? SimDriveError)?.code == .guestConnection { await session?.releaseInputs() }
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
