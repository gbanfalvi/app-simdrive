import Foundation
import SimDriveNative

/// Booted simulators, as `simctl list` reports them.
enum BootedSimulators {
    private static let bootedAlias = "booted"

    private struct Listing: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let deviceTypeIdentifier: String?
    }

    static func list(tools: DeveloperTools) async throws -> JSONValue {
        let devices = try await booted(tools: tools)
        return .array(devices.map { runtime, device in
            ["udid": .string(device.udid), "name": .string(device.name), "runtime": .string(runtime),
             "deviceType": JSONValue(device.deviceTypeIdentifier)]
        })
    }

    /// A UDID, or the one booted simulator for `booted`.
    static func resolve(_ identifier: String, tools: DeveloperTools) async throws -> String {
        guard identifier == bootedAlias else {
            guard UUID(uuidString: identifier) != nil else {
                throw SimDriveError.usage("\"\(identifier)\" is neither a simulator UDID nor booted")
            }
            return identifier
        }
        let devices = try await booted(tools: tools)
        guard devices.count == 1, let device = devices.first?.device else {
            let names = devices.map { "\($0.device.name) (\($0.device.udid))" }.joined(separator: ", ")
            throw SimDriveError(.ambiguousDevice, devices.isEmpty ? "No simulator is booted." : "Several simulators are booted: \(names). Pass a UDID.")
        }
        return device.udid
    }

    private static func booted(tools: DeveloperTools) async throws -> [(runtime: String, device: Device)] {
        let result = try await tools.simctl(["list", "devices", "booted", "-j"])
        let listing = try JSONDecoder().decode(Listing.self, from: Data(result.standardOutput.utf8))
        return listing.devices.flatMap { runtime, devices in
            devices.map { (runtime: runtime.components(separatedBy: ".").last ?? runtime, device: $0) }
        }.sorted { $0.device.name < $1.device.name }
    }
}
