import Foundation
import ObjectiveC

/// CoreSimulator's screen adapter: the framebuffer IO port whose screens `simctl io enumerate` lists.
@MainActor
struct ScreenAdapter {
    private typealias EnumerateFunction = @convention(c) (NSObject, Selector, DispatchQueue,
                                                          @escaping @Sendable @convention(block) (NSArray?) -> Void) -> Void
    private typealias UInt32Getter = @convention(c) (NSObject, Selector) -> UInt32

    private static let portIdentifier = "com.apple.framebuffer.server"
    private static let enumerateSelector = NSSelectorFromString("enumerateScreensWithCompletionQueue:completionHandler:")
    /// A local round trip, which takes a few milliseconds.
    private static let enumerationLimit: Duration = .seconds(2)
    private static let replies = DispatchQueue(label: "simdrive.screens.replies")

    private let adapter: NSObject

    init(device: NSObject) throws {
        let ports = Self.object(device, "io").flatMap { Self.object($0, "ioPorts") } as? [NSObject] ?? []
        guard let port = ports.first(where: { Self.object($0, "portIdentifier") as? String == Self.portIdentifier }),
              let adapter = Self.object(port, "descriptor"), adapter.responds(to: Self.enumerateSelector) else {
            throw SimDriveError(.screenAdapter, "CoreSimulator has no screen adapter for this simulator.")
        }
        self.adapter = adapter
    }

    /// Each screen's interface orientation by screen ID, leaving out screens without one.
    func interfaceOrientations() async throws -> [Int: InterfaceOrientation] {
        let enumerate = unsafeBitCast(adapter.method(for: Self.enumerateSelector), to: EnumerateFunction.self)
        return try await waitForCompletion(within: Self.enumerationLimit,
                                           timeout: SimDriveError(.screenAdapterTimeout, "CoreSimulator did not list the screens.")) { done in
            enumerate(adapter, Self.enumerateSelector, Self.replies) { screens in
                done(Self.interfaceOrientations(of: screens as? [NSObject] ?? []))
            }
        }
    }

    private nonisolated static func interfaceOrientations(of screens: [NSObject]) -> [Int: InterfaceOrientation] {
        var orientations: [Int: InterfaceOrientation] = [:]
        for screen in screens {
            guard let properties = object(screen, "screenProperties"), let id = uint32(properties, "screenID"),
                  let orientation = uint32(properties, "uiOrientation").flatMap(InterfaceOrientation.init(screenValue:)) else {
                continue
            }
            orientations[Int(id)] = orientation
        }
        return orientations
    }

    private nonisolated static func object(_ receiver: NSObject, _ getter: String) -> NSObject? {
        let selector = NSSelectorFromString(getter)
        guard receiver.responds(to: selector) else { return nil }
        return receiver.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private nonisolated static func uint32(_ receiver: NSObject, _ getter: String) -> UInt32? {
        let selector = NSSelectorFromString(getter)
        guard receiver.responds(to: selector) else { return nil }
        return unsafeBitCast(receiver.method(for: selector), to: UInt32Getter.self)(receiver, selector)
    }
}
