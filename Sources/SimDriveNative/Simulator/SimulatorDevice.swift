import Foundation
import ObjectiveC

/// A simulator's CoreSimulator `SimDevice`, which looks up the guest's Mach services.
@MainActor
package final class SimulatorDevice {
    private typealias ContextFunction = @convention(c) (AnyClass, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSObject?
    private typealias DeviceSetFunction = @convention(c) (NSObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSObject?
    private typealias LookUpFunction = @convention(c) (NSObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt32
    private typealias PostFunction = @convention(c) (NSObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool

    private static let bootedState = "Booted"
    private static let lastBootedAtKey = "lastBootedAt"
    private static let tvOSRuntimePrefix = "com.apple.CoreSimulator.SimRuntime.tvOS-"
    private static var contexts: [String: NSObject] = [:]

    let udid: String
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
            throw SimDriveError(.deviceSet, "CoreSimulator has no default device set: \(error?.localizedDescription ?? "no reason given")")
        }
        guard let uuid = UUID(uuidString: udid), let device = devices[uuid] else {
            throw SimDriveError(.deviceMissing, "No simulator has the UDID \(udid).")
        }
        return SimulatorDevice(udid: udid, device: device)
    }

    package var name: String { string(forKey: "name") ?? udid }
    package var deviceTypeIdentifier: String? { string(forKey: "deviceTypeIdentifier") }
    package var state: String? { string(forKey: "stateString") }
    package var isBooted: Bool { state == Self.bootedState }
    /// An Apple TV takes its remote's buttons, not touches.
    package var hasTouchscreen: Bool { !(string(forKey: "runtimeIdentifier")?.hasPrefix(Self.tvOSRuntimePrefix) ?? false) }
    package var majorOSVersion: Int? { string(forKey: "runtimeIdentifier").flatMap(Self.majorOSVersion(ofRuntime:)) }
    package var lastBootedAt: Date? {
        guard device.responds(to: NSSelectorFromString(Self.lastBootedAtKey)) else { return nil }
        return device.value(forKey: Self.lastBootedAtKey) as? Date
    }

    /// From a runtime identifier such as `com.apple.CoreSimulator.SimRuntime.iOS-18-3`.
    static func majorOSVersion(ofRuntime identifier: String) -> Int? {
        identifier.split(separator: ".").last?.split(separator: "-").dropFirst().first.flatMap { Int($0) }
    }

    /// A caller-owned send right to the guest's Mach service `name`.
    func lookUp(_ name: String) throws -> UInt32 {
        var error: NSError?
        let selector = NSSelectorFromString("lookup:error:")
        let lookUp = unsafeBitCast(device.method(for: selector), to: LookUpFunction.self)
        let port = lookUp(device, selector, name as NSString, &error)
        guard port != 0, port != UInt32.max else {
            throw SimDriveError(.guestLookup, "The guest has no \(name) service: \(error?.localizedDescription ?? "no reason given")")
        }
        return port
    }

    func hasService(_ name: String) -> Bool {
        guard let port = try? lookUp(name) else { return false }
        mach_port_deallocate(mach_task_self_, port)
        return true
    }

    /// Posts a Darwin notification in the guest, as `notifyutil -p` there would.
    package func postDarwinNotification(_ name: String) throws {
        let selector = NSSelectorFromString("postDarwinNotification:error:")
        guard device.responds(to: selector) else {
            throw SimDriveError(.guestNotification, "CoreSimulator cannot post notifications to \(self.name).")
        }
        var error: NSError?
        let post = unsafeBitCast(device.method(for: selector), to: PostFunction.self)
        guard post(device, selector, name as NSString, &error) else {
            throw SimDriveError(.guestNotification, "Could not post \(name): \(error?.localizedDescription ?? "no reason given")")
        }
    }

    /// A sender of the guest's accessibility requests, or nil when CoreSimulator cannot send them.
    func accessibilityChannel(timeout: DispatchTimeInterval) -> AccessibilityChannel? {
        guard device.responds(to: AccessibilityChannel.selector) else { return nil }
        return AccessibilityChannel(device: device, timeout: timeout)
    }

    private func string(forKey key: String) -> String? {
        guard device.responds(to: NSSelectorFromString(key)) else { return nil }
        return device.value(forKey: key) as? String
    }

    private static func serviceContext(developerDirectory: String) throws -> NSObject {
        if let context = contexts[developerDirectory] { return context }
        try NativeFrameworks.loadSynchronously(NativeFrameworks.coreSimulatorPath)
        guard let contextClass = NSClassFromString("SimServiceContext") else {
            throw SimDriveError(.coreSimulator, "CoreSimulator has no SimServiceContext class.")
        }
        let selector = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        guard let method = class_getClassMethod(contextClass, selector) else {
            throw SimDriveError(.coreSimulator, "SimServiceContext has no sharedServiceContextForDeveloperDir:error:.")
        }
        let makeContext = unsafeBitCast(method_getImplementation(method), to: ContextFunction.self)
        var error: NSError?
        guard let context = makeContext(contextClass, selector, developerDirectory as NSString, &error) else {
            throw SimDriveError(.coreSimulator, "No CoreSimulator service for \(developerDirectory): \(error?.localizedDescription ?? "no reason given")")
        }
        contexts[developerDirectory] = context
        return context
    }
}

/// Sends accessibility requests to a simulator's guest and waits for each reply. Callable from any thread.
struct AccessibilityChannel: @unchecked Sendable {
    private typealias SendFunction = @convention(c) (NSObject, Selector, NSObject, DispatchQueue,
                                                     @escaping @convention(block) (NSObject?) -> Void) -> Void

    fileprivate static let selector = NSSelectorFromString("sendAccessibilityRequestAsync:completionQueue:completionHandler:")

    private final class Reply: @unchecked Sendable {
        var value: NSObject?
    }

    private let device: NSObject
    private let timeout: DispatchTimeInterval
    private let replies = DispatchQueue(label: "simdrive.accessibility.replies")

    fileprivate init(device: NSObject, timeout: DispatchTimeInterval) {
        self.device = device
        self.timeout = timeout
    }

    /// The guest's reply, or nil when it does not answer in time.
    func send(_ request: NSObject) -> NSObject? {
        let answered = DispatchSemaphore(value: 0)
        let reply = Reply()
        let send = unsafeBitCast(device.method(for: Self.selector), to: SendFunction.self)
        send(device, Self.selector, request, replies) { response in
            reply.value = response
            answered.signal()
        }
        guard answered.wait(timeout: .now() + timeout) == .success else { return nil }
        return reply.value
    }
}
