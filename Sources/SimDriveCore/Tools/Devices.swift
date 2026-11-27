import Foundation
import SimDriveNative

/// Whether a device is a simulator or a physical device, as `list` reports it.
enum DeviceKind: String, Sendable {
    case simulator, physical
}

/// The device a command addresses: a simulator by its UDID, or a physical device by CoreDevice's identifier, which also
/// keys its daemon and state files.
struct DeviceTarget: Equatable, Sendable {
    let kind: DeviceKind
    let id: String
}

/// Booted simulators, as `simctl list` reports them, and paired physical devices, as CoreDevice lists them.
@MainActor
enum Devices {
    private static let bootedAlias = "booted"

    private struct Listing: Decodable {
        let devices: [String: [Simulator]]
    }

    private struct Simulator: Decodable {
        let udid: String
        let name: String
        let state: String
        let deviceTypeIdentifier: String?
    }

    /// Booted simulators, then connected physical devices.
    static func list(tools: DeveloperTools) async throws -> JSONValue {
        let simulators = try await booted(tools: tools).map { runtime, device -> JSONValue in
            ["kind": .string(DeviceKind.simulator.rawValue), "udid": .string(device.udid), "name": .string(device.name),
             "runtime": .string(runtime), "deviceType": JSONValue(device.deviceTypeIdentifier)]
        }
        let physical = try await PhysicalDevices.paired().filter { $0.isConnected }.map { device -> JSONValue in
            ["kind": .string(DeviceKind.physical.rawValue), "udid": .string(device.identifier.uuidString),
             "hardwareUDID": JSONValue(device.udid), "name": .string(device.name),
             "runtime": .string(runtime(of: device)), "deviceType": JSONValue(device.productType)]
        }
        return .array(simulators + physical)
    }

    /// The device `name` names: `booted` for the one booted simulator, a simulator's UDID, or a physical device's
    /// CoreDevice identifier or hardware UDID.
    static func resolve(_ name: String, tools: DeveloperTools) async throws -> DeviceTarget {
        if name == bootedAlias {
            let devices = try await booted(tools: tools)
            guard devices.count == 1, let device = devices.first?.device else {
                let names = devices.map { "\($0.device.name) (\($0.device.udid))" }.joined(separator: ", ")
                throw SimDriveError(.ambiguousDevice, devices.isEmpty ? "No simulator is booted." : "Several simulators are booted: \(names). Pass a UDID.")
            }
            return DeviceTarget(kind: .simulator, id: device.udid)
        }
        // A known simulator needs no CoreDevice, which takes a second or two to start.
        if isSimulator(name, tools: tools) { return DeviceTarget(kind: .simulator, id: name) }
        guard let target = target(named: name, among: try await PhysicalDevices.paired()) else {
            throw SimDriveError.usage("\"\(name)\" is neither a simulator UDID, a paired device's identifier or UDID, nor booted")
        }
        return target
    }

    /// The physical device of `name`, by CoreDevice identifier or hardware UDID.
    static func target(named name: String, among devices: [PhysicalDeviceRecord]) -> DeviceTarget? {
        devices.first { $0.isNamed(name) }.map { DeviceTarget(kind: .physical, id: $0.identifier.uuidString) }
    }

    /// Named as `simctl` names runtimes, such as `iOS-27-2-1`.
    static func runtime(of device: PhysicalDeviceRecord) -> String {
        ([device.platform] + (device.osVersion?.split(separator: ".").map(String.init) ?? [])).joined(separator: "-")
    }

    private static func isSimulator(_ name: String, tools: DeveloperTools) -> Bool {
        UUID(uuidString: name) != nil && (try? SimulatorDevice.find(udid: name, developerDirectory: tools.developerDirectory)) != nil
    }

    private static func booted(tools: DeveloperTools) async throws -> [(runtime: String, device: Simulator)] {
        let result = try await tools.simctl(["list", "devices", "booted", "-j"])
        let listing = try JSONDecoder().decode(Listing.self, from: Data(result.standardOutput.utf8))
        return listing.devices.flatMap { runtime, devices in
            devices.map { (runtime: runtime.components(separatedBy: ".").last ?? runtime, device: $0) }
        }.sorted { $0.device.name < $1.device.name }
    }
}
