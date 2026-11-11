import Foundation
import SimDriveCore

@main
@MainActor
struct SimDrive {
    private static let noDaemonFlag = "--no-daemon"
    private static let helpNames: Set<String> = ["-h", "--help", "help"]
    private static let listCommand = "list"
    private static let runCommand = "run"
    private static let standardInputPath = "-"
    private static let inlineStepsOption = "--json"

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let runsInProcess = arguments.contains(noDaemonFlag)
        arguments.removeAll { $0 == noDaemonFlag }
        guard let target = arguments.first, !helpNames.contains(target) else {
            print(CommandParser.usage)
            exit(EXIT_SUCCESS)
        }
        let response: DaemonResponse
        do {
            response = try await respond(to: target, Array(arguments.dropFirst()), runsInProcess: runsInProcess)
        } catch {
            response = .failure(error)
        }
        let output = (try? JSONEncoder.line.encode(response)).map { String(decoding: $0, as: UTF8.self) } ?? "{\"ok\":false}"
        print(output)
        exit(response.ok ? EXIT_SUCCESS : EXIT_FAILURE)
    }

    private static func respond(to target: String, _ arguments: [String], runsInProcess: Bool) async throws -> DaemonResponse {
        let tools = ToolRunner(developerDirectory: try await ToolRunner.resolveDeveloperDirectory())
        if target == listCommand { return .success(try await Simulators.listBooted(tools: tools)) }
        let udid = try await Simulators.resolve(target, tools: tools)
        let commandArguments = try inlineSteps(arguments)
        let command = try CommandParser.parse(commandArguments)
        let workingDirectory = FileManager.default.currentDirectoryPath
        switch command {
        case .serve:
            try await DaemonServer(udid: udid, tools: tools).run()
            exit(EXIT_SUCCESS)
        case .stop:
            return try await DaemonClient.stop(udid: udid, tools: tools)
        default:
            guard runsInProcess else {
                return try await DaemonClient.send(udid: udid, arguments: commandArguments, workingDirectory: workingDirectory,
                                                   tools: tools)
            }
            let session = try await DeviceSession.open(udid: udid, tools: tools)
            do {
                let result = try await session.execute(command, workingDirectory: workingDirectory)
                await session.close()
                return .success(result)
            } catch {
                await session.close()
                throw error
            }
        }
    }

    /// Replaces a steps file or standard input with its contents, since the daemon does not share this directory or input.
    private static func inlineSteps(_ arguments: [String]) throws -> [String] {
        guard arguments.first == runCommand, arguments.count == 2 else { return arguments }
        let source = arguments[1]
        let data = source == standardInputPath
            ? FileHandle.standardInput.readDataToEndOfFile()
            : try Data(contentsOf: URL(fileURLWithPath: source))
        return [runCommand, inlineStepsOption, String(decoding: data, as: UTF8.self)]
    }
}
