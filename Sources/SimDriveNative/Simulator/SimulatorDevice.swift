import Foundation
import ObjectiveC

/// A simulator's CoreSimulator `SimDevice`, which looks up the guest's Mach services.
@MainActor
package final class SimulatorDevice {
    private typealias ContextFunction = @convention(c) (AnyClass, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSObject?
    private typealias DeviceSetFunction = @convention(c) (NSObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>) -> NSObject?
    private typealias LookUpFunction = @convention(c) (NSObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> UInt32
    private typealias PostFunction = @convention(c) (NSObject, Selector, NSString, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool
    private typealias NotificationStateFunction = @convention(c) (NSObject, Selector, UnsafeMutablePointer<UInt64>, NSString,
                                                                  AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool
    private typealias SetNotificationStateFunction = @convention(c) (NSObject, Selector, UInt64, NSString,
                                                                     AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool
    private typealias SupportsFeatureFunction = @convention(c) (NSObject, Selector, NSString) -> Bool
    private typealias ReadIntFunction = @convention(c) (NSObject, Selector) -> Int
    private typealias SetIntFunction = @convention(c) (NSObject, Selector, Int, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool
    private typealias SetBoolFunction = @convention(c) (NSObject, Selector, Bool, AutoreleasingUnsafeMutablePointer<NSError?>) -> Bool

    /// A setting CoreSimulator changes itself, as `simctl ui` does.
    package enum InterfaceOption: Sendable {
        case appearance
        case textSize
        case increaseContrast

        /// The option's choices, named as simdrive names them, in the order CoreSimulator numbers them.
        package var choices: [String] {
            switch self {
            case .appearance: ["light", "dark"]
            case .textSize: [
                "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
                "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large",
                "accessibility-extra-extra-extra-large",
            ]
            case .increaseContrast: ["off", "on"]
            }
        }

        fileprivate var getter: Selector {
            switch self {
            case .appearance: NSSelectorFromString("currentUIInterfaceStyle")
            case .textSize: NSSelectorFromString("currentContentSizeCategory")
            case .increaseContrast: NSSelectorFromString("currentIncreaseContrastMode")
            }
        }

        fileprivate var setter: Selector {
            switch self {
            case .appearance: NSSelectorFromString("setUIInterfaceStyle:error:")
            case .textSize: NSSelectorFromString("setContentSizeCategory:error:")
            case .increaseContrast: NSSelectorFromString("setIncreaseContrastEnabled:error:")
            }
        }
    }

    private static let bootedState = "Booted"
    private static let lastBootedAtKey = "lastBootedAt"
    private static let dataPathKey = "dataPath"
    private static let deviceTypeKey = "deviceType"
    private static let screenScaleKey = "mainScreenScale"
    private static let tvOSRuntimePrefix = "com.apple.CoreSimulator.SimRuntime.tvOS-"
    private static let runtimeKey = "runtime"
    private static let runtimeRootKey = "root"
    private static let launchDaemonsPath = "System/Library/LaunchDaemons"
    /// CoreSimulator numbers each interface option's choices from 1; 0 and below mean the device lacks it.
    private static let firstInterfaceValue = 1
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
    /// The host directory holding the guest's own `/tmp`, `/var` and home directories.
    package var dataDirectory: URL? {
        guard device.responds(to: NSSelectorFromString(Self.dataPathKey)) else { return nil }
        let value = device.value(forKey: Self.dataPathKey)
        return value as? URL ?? (value as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    /// Pixels per point of the device type's screens.
    package var screenScale: Double? {
        guard device.responds(to: NSSelectorFromString(Self.deviceTypeKey)),
              let deviceType = device.value(forKey: Self.deviceTypeKey) as? NSObject,
              deviceType.responds(to: NSSelectorFromString(Self.screenScaleKey)) else {
            return nil
        }
        return (deviceType.value(forKey: Self.screenScaleKey) as? NSNumber)?.doubleValue
    }
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

    /// The directory holding the guest's system files.
    var runtimeRoot: URL? {
        guard device.responds(to: NSSelectorFromString(Self.runtimeKey)),
              let root = (device.value(forKey: Self.runtimeKey) as? NSObject)?.value(forKey: Self.runtimeRootKey) as? String else {
            return nil
        }
        return URL(fileURLWithPath: root, isDirectory: true)
    }

    /// Whether the runtime ships the launchd daemon `label`, running or not.
    package func hasLaunchDaemon(_ label: String) -> Bool {
        guard let root = runtimeRoot else { return false }
        return FileManager.default.fileExists(atPath: root.appending(path: "\(Self.launchDaemonsPath)/\(label).plist").path)
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

    /// `option`'s current choice, one of its `choices`; nil when the device lacks the option or reports another value.
    package func interfaceChoice(_ option: InterfaceOption) -> String? {
        guard device.responds(to: option.getter) else { return nil }
        let read = unsafeBitCast(device.method(for: option.getter), to: ReadIntFunction.self)
        let index = read(device, option.getter) - Self.firstInterfaceValue
        return option.choices.indices.contains(index) ? option.choices[index] : nil
    }

    /// Sets `option` to one of its `choices`.
    package func setInterfaceChoice(_ option: InterfaceOption, to choice: String) throws {
        guard let index = option.choices.firstIndex(of: choice) else {
            throw SimDriveError(.interfaceOption, "\(option) has no choice \(choice).")
        }
        guard device.responds(to: option.setter) else {
            throw SimDriveError(.interfaceOption, "CoreSimulator cannot change \(option) on \(name).")
        }
        var error: NSError?
        let method = device.method(for: option.setter)
        let changed = switch option {
        case .increaseContrast: unsafeBitCast(method, to: SetBoolFunction.self)(device, option.setter, index != 0, &error)
        case .appearance, .textSize:
            unsafeBitCast(method, to: SetIntFunction.self)(device, option.setter, index + Self.firstInterfaceValue, &error)
        }
        guard changed else {
            throw SimDriveError(.interfaceOption, "Could not change \(option): \(error?.localizedDescription ?? "no reason given")")
        }
    }

    /// Whether the guest has started a screen, before which an accessibility read can leave the server unanswering.
    package func hasStartedScreen() async throws -> Bool {
        try await ScreenAdapter(device: device).hasStartedScreen()
    }

    /// Each screen's backlight by screen ID; screens that report none, as on Apple TV, are left out.
    package func backlights() async throws -> [Int: Backlight] {
        try await ScreenAdapter(device: device).backlightStates().mapValues(Backlight.init(state:))
    }

    /// The state of a Darwin notification in the guest, as `notifyutil -g` there would read it.
    package func darwinNotificationState(_ name: String) throws -> UInt64 {
        let selector = NSSelectorFromString("darwinNotificationGetState:name:error:")
        guard device.responds(to: selector) else {
            throw SimDriveError(.guestNotification, "CoreSimulator cannot read notification states on \(self.name).")
        }
        var state: UInt64 = 0
        var error: NSError?
        let read = unsafeBitCast(device.method(for: selector), to: NotificationStateFunction.self)
        guard read(device, selector, &state, name as NSString, &error) else {
            throw SimDriveError(.guestNotification, "Could not read \(name): \(error?.localizedDescription ?? "no reason given")")
        }
        return state
    }

    /// Sets a Darwin notification's state in the guest, as `notifyutil -s` there would, without posting it.
    package func setDarwinNotificationState(_ state: UInt64, of name: String) throws {
        let selector = NSSelectorFromString("darwinNotificationSetState:name:error:")
        guard device.responds(to: selector) else {
            throw SimDriveError(.guestNotification, "CoreSimulator cannot set notification states on \(self.name).")
        }
        var error: NSError?
        let set = unsafeBitCast(device.method(for: selector), to: SetNotificationStateFunction.self)
        guard set(device, selector, state, name as NSString, &error) else {
            throw SimDriveError(.guestNotification, "Could not set \(name): \(error?.localizedDescription ?? "no reason given")")
        }
    }

    /// Whether the device's type and runtime support a CoreSimulator feature, such as
    /// `com.apple.UIKit.SimulatorSlowMotionStateful`.
    package func supportsFeature(_ feature: String) -> Bool {
        let selector = NSSelectorFromString("supportsFeature:")
        guard device.responds(to: selector) else { return false }
        let supports = unsafeBitCast(device.method(for: selector), to: SupportsFeatureFunction.self)
        return supports(device, selector, feature as NSString)
    }

    /// Each connected screen's interface orientation by screen ID, as `simctl io enumerate` lists them; screens without
    /// one are left out.
    package func interfaceOrientations() async throws -> [Int: InterfaceOrientation] {
        try await ScreenAdapter(device: device).interfaceOrientations()
    }

    /// Sends running apps a memory warning, as `SimDevice simulateMemoryWarning` does: the guest watches for this file.
    /// Nil when CoreSimulator reports no file for the device.
    package func memoryWarningFile() -> URL? {
        string(forKey: "memoryWarningFilePath").map { URL(fileURLWithPath: $0) }
    }

    /// The current pixels of screen `screenID`, or nil when CoreSimulator does not share them.
    package func screenFrame(screenID: Int) -> ScreenFrame? {
        ScreenFramebuffers(device: device).frame(screenID: screenID)
    }

    /// The BGRA bytes of a square of `side` pixels around `unitPoint` of screen `screenID`, in the panel's native
    /// orientation as the digitizer's unit coordinates are; nil when CoreSimulator does not share the screen's pixels.
    package func screenPixels(screenID: Int, around unitPoint: CGPoint, side: Int) -> [UInt8]? {
        ScreenFramebuffers(device: device).pixels(screenID: screenID, around: unitPoint, side: side)
    }

    /// A sender of the guest's accessibility requests, or nil when CoreSimulator cannot send them.
    func accessibilityChannel() -> AccessibilityChannel? {
        guard device.responds(to: AccessibilityChannel.selector) else { return nil }
        return AccessibilityChannel(device: device)
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

    /// One request's answer, and whether its sender stopped waiting first; whichever side comes second settles it.
    private final class Reply: @unchecked Sendable {
        private let lock = NSLock()
        private var isAnswered = false
        private var isAbandoned = false
        private var response: NSObject?

        /// From the completion handler: true when the sender had already stopped waiting.
        func answer(_ response: NSObject?) -> Bool {
            lock.withLock {
                isAnswered = true
                self.response = response
                return isAbandoned
            }
        }

        /// From the sender, past its wait: nil when it is now abandoned, else the answer that raced in.
        func abandonUnlessAnswered() -> NSObject?? {
            lock.withLock {
                guard isAnswered else {
                    isAbandoned = true
                    return nil
                }
                return .some(response)
            }
        }

        var value: NSObject? { lock.withLock { response } }
    }

    /// What became of a request.
    enum Outcome {
        case answered(NSObject)
        case unanswered
        /// CoreSimulator completed without a response, as when it cannot reach the guest's accessibility service.
        case unreachable
    }

    /// One request's own limit within its read's deadline, as idb, AXe and NeoSimulator use (F33).
    private static let requestLimit: TimeInterval = 5

    private let device: NSObject
    private let replies = DispatchQueue(label: "simdrive.accessibility.replies")
    private let gate = RequestGate()

    fileprivate init(device: NSObject) {
        self.device = device
    }

    /// Requests the guest has not answered since their senders stopped waiting.
    var abandoned: Int { gate.abandoned }

    /// Sends once no earlier request is in flight, and waits up to `requestLimit` for the answer, or to `deadline` if
    /// sooner. A request that goes unanswered stays in flight, so the next one waits for it rather than queueing behind
    /// it in the guest.
    func send(_ request: NSObject, deadline: DispatchTime) -> Outcome {
        let now = DispatchTime.now()
        guard now < deadline else { return .unanswered }
        let wallDeadline = Date(timeIntervalSinceNow: Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1e9)
        guard gate.enter(before: wallDeadline) else { return .unanswered }
        let answered = DispatchSemaphore(value: 0)
        let reply = Reply()
        let gate = gate
        let send = unsafeBitCast(device.method(for: Self.selector), to: SendFunction.self)
        send(device, Self.selector, request, replies) { response in
            gate.answered(wasAbandoned: reply.answer(response))
            answered.signal()
        }
        guard answered.wait(timeout: min(deadline, .now() + Self.requestLimit)) == .success else {
            guard let raced = reply.abandonUnlessAnswered() else {
                gate.abandon()
                return .unanswered
            }
            return raced.map(Outcome.answered) ?? .unreachable
        }
        return reply.value.map(Outcome.answered) ?? .unreachable
    }
}
