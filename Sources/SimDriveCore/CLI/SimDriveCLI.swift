import Foundation

/// The command line: runs a command through the device's daemon, or in this process, and prints one JSON line.
@MainActor
package enum SimDriveCLI {
    private static let noDaemonFlag = "--no-daemon"
    private static let helpNames: Set<String> = ["-h", "--help", "help"]
    private static let listCommand = "list"
    private static let runCommand = "run"
    private static let standardInputPath = "-"
    private static let inlineStepsOption = "--json"

    /// Runs the command of `arguments`, which exclude the executable, and returns the process's exit status.
    package static func run(arguments: [String]) async -> Int32 {
        var arguments = arguments
        let runsInProcess = arguments.contains(noDaemonFlag)
        arguments.removeAll { $0 == noDaemonFlag }
        guard let target = arguments.first, !helpNames.contains(target) else {
            print(CommandParser.usage)
            return EXIT_SUCCESS
        }
        let response: CommandResponse
        do {
            response = try await respond(to: target, Array(arguments.dropFirst()), runsInProcess: runsInProcess)
        } catch {
            response = .failure(error)
        }
        let output = (try? JSONEncoder.line.encode(response)).map { String(decoding: $0, as: UTF8.self) } ?? "{\"ok\":false}"
        print(output)
        return response.ok ? EXIT_SUCCESS : EXIT_FAILURE
    }

    private static func respond(to target: String, _ arguments: [String], runsInProcess: Bool) async throws -> CommandResponse {
        let tools = DeveloperTools(developerDirectory: try await DeveloperTools.resolveDeveloperDirectory())
        if target == listCommand { return .success(try await BootedSimulators.list(tools: tools)) }
        let udid = try await BootedSimulators.resolve(target, tools: tools)
        let commandArguments = try inlineSteps(arguments)
        let command = try CommandParser.parse(commandArguments)
        let workingDirectory = FileManager.default.currentDirectoryPath
        switch command {
        case .serve:
            try await DaemonServer(udid: udid, tools: tools).run()
            exit(EXIT_SUCCESS)
        case .stop:
            return try await DaemonClient.stop(udid: udid, tools: tools)
        case .logs(let query):
            // Needs only simctl, so it neither waits behind the daemon's queue nor holds it while it waits.
            try StatePaths.prepare()
            return .success(try await DeviceLogs(udid: udid, tools: tools).read(query))
        default:
            guard runsInProcess else {
                return try await DaemonClient.send(udid: udid, arguments: commandArguments, workingDirectory: workingDirectory,
                                                   tools: tools)
            }
            let session = try await DeviceSession.open(udid: udid, tools: tools)
            let response: CommandResponse
            do { response = .success(try await session.execute(command, workingDirectory: workingDirectory)) } catch {
                response = .failure(error)
            }
            await session.close()
            return response
        }
    }

    /// Replaces a steps file or standard input with its contents, since the daemon does not share this directory or input.
    private static func inlineSteps(_ arguments: [String]) throws -> [String] {
        guard arguments.first == runCommand, !arguments.contains(inlineStepsOption),
              let index = arguments.indices.dropFirst().first(where: { !arguments[$0].hasPrefix("--") }) else {
            return arguments
        }
        let source = arguments[index]
        let data = source == standardInputPath
            ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: source))
        var inlined = arguments
        inlined.replaceSubrange(index...index, with: [inlineStepsOption, String(decoding: data, as: UTF8.self)])
        return inlined
    }
}
