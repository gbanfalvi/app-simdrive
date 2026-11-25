import Accessibility
import AppKit
import ObjectiveC

/// A simulator's frontmost app.
package struct AccessibilityApplication: Equatable, Sendable {
    package let name: String?
    package let pid: Int32?
    /// In points; it turns with the interface on some devices and not on others.
    package let screenSize: CGSize

    package init(name: String?, pid: Int32?, screenSize: CGSize) {
        self.name = name
        self.pid = pid
        self.screenSize = screenSize
    }
}

/// An app, and one of its elements with the element's descendants.
package struct AccessibilitySnapshot: Equatable, Sendable {
    package let application: AccessibilityApplication
    package let element: AccessibilityElement

    /// The same app with another element, as one whose windows were rearranged.
    package func with(element: AccessibilityElement) -> AccessibilitySnapshot {
        AccessibilitySnapshot(application: application, element: element)
    }
}

/// A simulator's accessibility hierarchy, read from the Mac through AccessibilityPlatformTranslation, as Simulator and
/// idb read it. CoreSimulator carries the translator's requests to the guest's accessibility server.
package final class SimulatorAccessibility: @unchecked Sendable {
    private typealias FrontmostFunction = @convention(c) (NSObject, Selector, UInt32, NSString) -> NSObject?
    private typealias HitTestFunction = @convention(c) (NSObject, Selector, CGPoint, UInt32, NSString) -> NSObject?
    private typealias ApplicationForPidFunction = @convention(c) (NSObject, Selector, Int32) -> NSObject?

    private enum Limit {
        /// For all of one read's requests and retries. A Duo's first read after boot took 13–15 s, mostly while its
        /// accessibility server named no app; a large app's first hierarchy takes seconds.
        static let read: DispatchTimeInterval = .seconds(20)
        /// With `children`, far above any real app's hierarchy, so no tree is cut short; they only stop a runaway one.
        static let depth = 500
        static let children = 10_000
        /// Until the deadline: an app answers with nothing while it launches, and sometimes at random, and after a boot the
        /// guest names no app for several seconds.
        static let retryDelay: TimeInterval = 0.5
    }

    private enum Name {
        static let translator = "AXPTranslator"
        static let delegateProtocol = "AXPTranslationTokenDelegateHelper"
        static let snapshot = "AXTestingSnapshotParameterizedAttribute"
        static let customContent = "AXCustomContent"
        static let token = "bridgeDelegateToken"
        static let translation = "translation"
        static let pid = "pid"
    }

    private enum Call {
        static let sharedInstance = NSSelectorFromString("sharedInstance")
        static let frontmost = NSSelectorFromString("frontmostApplicationWithDisplayId:bridgeDelegateToken:")
        static let hitTest = NSSelectorFromString("objectAtPoint:displayId:bridgeDelegateToken:")
        static let applicationForPid = NSSelectorFromString("translationApplicationObjectForPid:")
        static let platformElement = NSSelectorFromString("macPlatformElementFromTranslation:")
        static let processAttribute = NSSelectorFromString("_accessibilityProcessAttribute:parameter:")
        static let attributeValue = NSSelectorFromString("accessibilityAttributeValue:")
    }

    /// The translator answers for the frontmost app whatever display it is given.
    private static let frontmostDisplayID: UInt32 = 0
    private static let retryHint = "Retry; for a minute after a simulator's first boot, its guest answers slowly."

    private let translator: NSObject
    /// The translator holds its delegate weakly.
    private let bridge: AccessibilityBridge
    private let token: NSString
    private let read: AccessibilityRead
    private let readsDisplays: Bool
    /// The translator blocks while the guest answers, so it never runs on the main actor.
    private let queue = DispatchQueue(label: "simdrive.accessibility")

    /// The device's accessibility, or nil when CoreSimulator or macOS cannot read it. `readsDisplays` asks each element
    /// for its display, on a device with several.
    @MainActor
    package static func open(device: SimulatorDevice, readsDisplays: Bool) async throws -> SimulatorAccessibility? {
        guard let channel = device.accessibilityChannel() else { return nil }
        try await NativeFrameworks.load(NativeFrameworks.accessibilityTranslationPath)
        guard let translatorClass = NSClassFromString(Name.translator),
              let delegateProtocol = objc_getProtocol(Name.delegateProtocol),
              let translator = (translatorClass as AnyObject).perform(Call.sharedInstance)?.takeUnretainedValue() as? NSObject else {
            return nil
        }
        class_addProtocol(AccessibilityBridge.self, delegateProtocol)
        let read = AccessibilityRead()
        return SimulatorAccessibility(translator: translator, bridge: AccessibilityBridge(channel: channel, read: read),
                                      token: device.udid as NSString, read: read, readsDisplays: readsDisplays)
    }

    private init(translator: NSObject, bridge: AccessibilityBridge, token: NSString, read: AccessibilityRead, readsDisplays: Bool) {
        self.translator = translator
        self.bridge = bridge
        self.readsDisplays = readsDisplays
        self.token = token
        self.read = read
        translator.setValue(true, forKey: "supportsDelegateTokens")
        translator.setValue(true, forKey: "accessibilityEnabled")
        translator.setValue(bridge, forKey: "bridgeTokenDelegate")
    }

    package func application() async throws -> AccessibilityApplication {
        try await perform { try self.frontmost().application }
    }

    /// The frontmost app with its windows' frames, in points from the app's own origin, which a split app keeps.
    package func windows() async throws -> (application: AccessibilityApplication, frames: [CGRect]) {
        try await perform {
            let (application, root) = try self.frontmost()
            let windows = (root as? NSAccessibilityElement)?.accessibilityChildren() ?? []
            return (application, windows.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityFrame() })
        }
    }

    /// The frontmost app's whole hierarchy. The testing snapshot lists what an alert or a sheet covers too, whatever
    /// client type its requests name, so a covered element is told apart by hit-testing its point.
    package func snapshot(detail: TreeDetail) async throws -> AccessibilitySnapshot {
        try await perform {
            let (application, root) = try self.frontmost()
            return AccessibilitySnapshot(application: application, element: try self.hierarchy(of: root, detail: detail))
        }
    }

    /// The hierarchy of the app process `pid` runs, in front or not; nil when the guest names no app for it.
    package func snapshot(ofProcess pid: Int32, detail: TreeDetail) async throws -> AccessibilitySnapshot? {
        try await perform {
            let make = unsafeBitCast(self.translator.method(for: Call.applicationForPid), to: ApplicationForPidFunction.self)
            guard let translation = make(self.translator, Call.applicationForPid, pid) else { return nil }
            let element = try self.platformElement(translation)
            guard let accessible = element as? NSAccessibilityElement else { return nil }
            let name = accessible.accessibilityLabel()?.trimmingCharacters(in: .whitespaces)
            let application = AccessibilityApplication(name: name?.isEmpty == false ? name : nil, pid: pid,
                                                       screenSize: accessible.accessibilityFrame().size)
            return AccessibilitySnapshot(application: application, element: try self.hierarchy(of: element, detail: detail))
        }
    }

    /// The VoiceOver element at a point of a display, or nil when there is none. `point` turns the app's screen size
    /// into points of the panel's native orientation. `display` is the simctl display index; single-display devices have 0.
    package func snapshot(at point: @escaping @Sendable (CGSize) -> CGPoint, display: Int,
                          detail: TreeDetail) async throws -> AccessibilitySnapshot? {
        try await perform {
            let (application, _) = try self.frontmost()
            let hitTest = unsafeBitCast(self.translator.method(for: Call.hitTest), to: HitTestFunction.self)
            self.read.failure = nil
            guard let translation = hitTest(self.translator, Call.hitTest, point(application.screenSize), UInt32(display),
                                            self.token) else {
                if let failure = self.read.failure, failure != .gone { throw self.error(for: failure, "The hit test went unanswered.") }
                return nil
            }
            let element = try self.hierarchy(of: try self.platformElement(translation), detail: detail)
            return AccessibilitySnapshot(application: application, element: element)
        }
    }

    private func frontmost() throws -> (application: AccessibilityApplication, element: NSObject) {
        let frontmost = unsafeBitCast(translator.method(for: Call.frontmost), to: FrontmostFunction.self)
        var answered = false
        let found = try retrying { () throws -> (AccessibilityApplication, NSObject)? in
            guard let translation = frontmost(translator, Call.frontmost, Self.frontmostDisplayID, token) else { return nil }
            answered = true
            let element = try platformElement(translation)
            guard let accessible = element as? NSAccessibilityElement, !accessible.accessibilityFrame().isEmpty else { return nil }
            let pid = translation.responds(to: NSSelectorFromString(Name.pid))
                ? (translation.value(forKey: Name.pid) as? NSNumber)?.int32Value : nil
            // SpringBoard's name is a space.
            let name = accessible.accessibilityLabel()?.trimmingCharacters(in: .whitespaces)
            let application = AccessibilityApplication(name: name?.isEmpty == false ? name : nil, pid: pid,
                                                       screenSize: accessible.accessibilityFrame().size)
            return (application, element)
        }
        guard let found else {
            guard answered else { throw error(for: read.failure ?? .unanswered, "The simulator's accessibility server did not answer.") }
            throw SimDriveError(.accessibilityTranslation, "The frontmost app has no frame yet; wait for it to finish launching.")
        }
        return found
    }

    private func platformElement(_ translation: NSObject) throws -> NSObject {
        translation.setValue(token, forKey: Name.token)
        guard let element = translator.perform(Call.platformElement, with: translation)?.takeUnretainedValue() as? NSObject else {
            throw SimDriveError(.accessibilityTranslation, "The accessibility translator returned no element.")
        }
        return element
    }

    /// One request returns the element's whole subtree. Custom content costs a request per VoiceOver element, so only
    /// full trees read it.
    private func hierarchy(of element: NSObject, detail: TreeDetail) throws -> AccessibilityElement {
        let parameters: NSDictionary = [
            "attributes": SnapshotAttribute.requested(for: detail, readsDisplays: readsDisplays).map(\.rawValue), "maxDepth": Limit.depth,
            "maxChildren": Limit.children, "maxArrayCount": Limit.children, "traverseFromParentsToChildren": true,
        ]
        let readsCustomContent = detail == .full
        let root = retrying {
            element.perform(Call.processAttribute, with: Name.snapshot, with: parameters).flatMap {
                AccessibilityElement(snapshot: $0.takeUnretainedValue()) { readsCustomContent ? customContent(of: $0) : [] }
            }
        }
        guard let root else { throw error(for: read.failure ?? .unanswered, "The app did not return its accessibility hierarchy.") }
        return root
    }

    /// Tries again until the read's deadline, also after a request went unanswered: the channel sends the next one only
    /// once the guest has answered it, so retries cannot pile up in the guest (F33).
    private func retrying<Result>(_ attempt: () throws -> Result?) rethrows -> Result? {
        while true {
            read.failure = nil
            if let result = try attempt() { return result }
            guard read.failure == nil || read.failure == .unanswered, DispatchTime.now() + Limit.retryDelay < read.deadline else {
                return nil
            }
            Thread.sleep(forTimeInterval: Limit.retryDelay)
        }
    }

    private func error(for failure: AccessibilityRead.Failure, _ unanswered: String) -> SimDriveError {
        switch failure {
        case .unanswered:
            let waiting = bridge.abandoned
            let queued = waiting > 0 ? " \(waiting) request\(waiting == 1 ? " is" : "s are") still unanswered in the guest." : ""
            return SimDriveError(.accessibilityTimeout, "\(unanswered)\(queued) \(Self.retryHint)")
        case .unreachable:
            return SimDriveError(.accessibilityUnavailable, "CoreSimulator cannot reach the simulator's accessibility service. \(Self.retryHint)")
        case .gone:
            return SimDriveError(.noElement, "The element is gone; read the tree again.")
        }
    }

    /// Snapshots leave out custom content, so each VoiceOver element is asked for its own.
    private func customContent(of object: AnyObject) -> [AccessibilityCustomContent] {
        guard let element = object as? NSObject else { return [] }
        if element.responds(to: NSSelectorFromString(Name.translation)),
           let translation = element.value(forKey: Name.translation) as? NSObject {
            translation.setValue(token, forKey: Name.token)
        }
        let classes = [NSArray.self, NSDictionary.self, NSString.self, NSAttributedString.self, AXCustomContent.self]
        guard let data = element.perform(Call.attributeValue, with: Name.customContent)?.takeUnretainedValue() as? Data,
              let contents = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: data) as? [AXCustomContent] else {
            return []
        }
        return contents.map { AccessibilityCustomContent(label: $0.label, value: $0.value, isImportant: $0.importance == .high) }
    }

    private func perform<Result: Sendable>(_ work: @escaping @Sendable () throws -> Result) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [read] in
                read.start(limit: Limit.read)
                continuation.resume(with: Swift.Result { try autoreleasepool(invoking: work) })
            }
        }
    }
}

/// The read in progress: its deadline, and why its last request failed. Only the accessibility queue touches it.
private final class AccessibilityRead: @unchecked Sendable {
    enum Failure { case unanswered, unreachable, gone }

    private(set) var deadline: DispatchTime = .now()
    var failure: Failure?

    func start(limit: DispatchTimeInterval) {
        deadline = .now() + limit
        failure = nil
    }
}

/// The translator's delegate, which sends its requests to the guest.
private final class AccessibilityBridge: NSObject, @unchecked Sendable {
    /// The translator's error for an element that is gone, or nothing accessible at a point.
    private static let noElementError: UInt64 = 8
    private static let errorKey = "error"

    private let channel: AccessibilityChannel
    private let read: AccessibilityRead

    var abandoned: Int { channel.abandoned }

    init(channel: AccessibilityChannel, read: AccessibilityRead) {
        self.channel = channel
        self.read = read
    }

    @objc(accessibilityTranslationDelegateBridgeCallbackWithToken:)
    func requestSender(token: NSString) -> Any {
        let (channel, read) = (channel, read)
        let send: @convention(block) (NSObject) -> NSObject? = { request in
            switch channel.send(request, deadline: read.deadline) {
            case .answered(let response):
                if Self.error(of: response) == Self.noElementError { read.failure = .gone }
                return response
            case .unanswered:
                read.failure = .unanswered
                return nil
            case .unreachable:
                read.failure = .unreachable
                return nil
            }
        }
        return send
    }

    private static func error(of response: NSObject) -> UInt64? {
        guard response.responds(to: NSSelectorFromString(errorKey)) else { return nil }
        return (response.value(forKey: errorKey) as? NSNumber)?.uint64Value
    }

    /// Frames stay in the guest's points.
    @objc(accessibilityTranslationConvertPlatformFrameToSystem:withToken:)
    func systemFrame(_ frame: CGRect, token: NSString) -> CGRect { frame }

    @objc(accessibilityTranslationRootParentWithToken:)
    func rootParent(token: NSString) -> Any? { nil }
}
