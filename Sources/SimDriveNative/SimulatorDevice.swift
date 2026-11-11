import Foundation
import ObjectiveC

/// A simulator's CoreSimulator `SimDevice`, which looks up the guest's Mach services.
@MainActor
package final class SimulatorDevice {
    private typealias ContextFunction = @convention(c) (AnyClass, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSObject?
    private typealias DeviceSetFunction = @convention(c) (NSObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSObject?
    private typealias LookUpFunction = @convention(c) (NSObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt32

    package static let missingServiceIdentifier = "guest-lookup"
    private static let bootedState = "Booted"
    private static let tvOSRuntimePrefix = "com.apple.CoreSimulator.SimRuntime.tvOS-"
    private static var contexts: [String: NSObject] = [:]

    package let udid: String
    private let device: NSObject

    private init(udid: String, device: NSObject) {
        self.udid = udid
        self.device = device
    }

    /// The simulator of `udid` in the default device set of `developerDirectory`'s CoreSimulator service.
    package static func find(udid: String, developerDirectory: String) throws -> SimulatorDevice {
        let context = try serviceContext(developerDirectory: developerDirectory)
        var error: NSError?
        let selector = NSSelectorFromString("defaultDeviceSetWithError:")
        let makeSet = unsafeBitCast(context.method(for: selector), to: DeviceSetFunction.self)
        guard let deviceSet = makeSet(context, selector, &error),
              let devices = deviceSet.value(forKey: "devicesByUDID") as? [UUID: NSObject] else {
            throw NativeError("device-set", "CoreSimulator has no default device set: \(error?.localizedDescription ?? "no reason given")")
        }
        guard let uuid = UUID(uuidString: udid), let device = devices[uuid] else {
            throw NativeError("device-missing", "No simulator has the UDID \(udid).")
        }
        return SimulatorDevice(udid: udid, device: device)
    }

    package var name: String { string(forKey: "name") ?? udid }
    package var deviceTypeIdentifier: String? { string(forKey: "deviceTypeIdentifier") }
    package var state: String? { string(forKey: "stateString") }
    package var isBooted: Bool { state == Self.bootedState }
    /// An Apple TV takes its remote's buttons, not touches.
    package var hasTouchscreen: Bool { !(string(forKey: "runtimeIdentifier")?.hasPrefix(Self.tvOSRuntimePrefix) ?? false) }

    /// A caller-owned send right to the guest's Mach service `name`.
    package func lookUp(_ name: String) throws -> UInt32 {
        var error: NSError?
        let selector = NSSelectorFromString("lookup:error:")
        let lookUp = unsafeBitCast(device.method(for: selector), to: LookUpFunction.self)
        let port = lookUp(device, selector, name as NSString, &error)
        guard port != 0, port != UInt32.max else {
            throw NativeError(Self.missingServiceIdentifier, "The guest has no \(name) service: \(error?.localizedDescription ?? "no reason given")")
        }
        return port
    }

    package func hasService(_ name: String) -> Bool {
        guard let port = try? lookUp(name) else { return false }
        mach_port_deallocate(mach_task_self_, port)
        return true
    }

    private func string(forKey key: String) -> String? {
        guard device.responds(to: NSSelectorFromString(key)) else { return nil }
        return device.value(forKey: key) as? String
    }

    private static func serviceContext(developerDirectory: String) throws -> NSObject {
        if let context = contexts[developerDirectory] { return context }
        try NativeFrameworks.loadSynchronously(NativeFrameworks.coreSimulatorPath)
        guard let contextClass = NSClassFromString("SimServiceContext") else {
            throw NativeError("core-simulator", "CoreSimulator has no SimServiceContext class.")
        }
        let selector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let method = class_getClassMethod(contextClass, selector) else {
            throw NativeError("core-simulator", "SimServiceContext has no sharedServiceContextForDeveloperDir:error:.")
        }
        let makeContext = unsafeBitCast(method_getImplementation(method), to: ContextFunction.self)
        var error: NSError?
        guard let context = makeContext(contextClass, selector, developerDirectory as NSString, &error) else {
            throw NativeError("core-simulator", "No CoreSimulator service for \(developerDirectory): \(error?.localizedDescription ?? "no reason given")")
        }
        contexts[developerDirectory] = context
        return context
    }
}
