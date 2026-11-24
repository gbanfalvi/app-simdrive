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

    /// Whether a screen has started: early in a boot every screen's backlight state reads unknown (-101), and the main
    /// panel reports a state about 85 s into a cold iPhone boot, 25 s after its interface orientation. A runtime that
    /// reports no backlight counts as started. Apple TV never reports one, so callers skip it.
    func hasStartedScreen() async throws -> Bool {
        let enumerate = unsafeBitCast(adapter.method(for: Self.enumerateSelector), to: EnumerateFunction.self)
        return try await waitForCompletion(within: Self.enumerationLimit,
                                           timeout: SimDriveError(.screenAdapterTimeout, "CoreSimulator did not list the screens.")) { done in
            enumerate(adapter, Self.enumerateSelector, Self.replies) { screens in
                done(Self.hasStartedScreen(backlightStates: (screens as? [NSObject] ?? []).map { screen in
                    Self.object(screen, "screenProperties").flatMap { Self.object($0, "backlight") }.flatMap { Self.uint32($0, "state") }
                        .map { Int32(bitPattern: $0) }
                }))
            }
        }
    }

    /// The decision alone, for tests: any known state, or none reported at all.
    nonisolated static func hasStartedScreen(backlightStates: [Int32?]) -> Bool {
        let reported = backlightStates.compactMap { $0 }
        return reported.isEmpty || reported.contains { $0 != unknownBacklightState }
    }

    private nonisolated static let unknownBacklightState: Int32 = -101

    nonisolated static func object(_ receiver: NSObject, _ getter: String) -> NSObject? {
        let selector = NSSelectorFromString(getter)
        guard receiver.responds(to: selector) else { return nil }
        return receiver.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    nonisolated static func uint32(_ receiver: NSObject, _ getter: String) -> UInt32? {
        let selector = NSSelectorFromString(getter)
        guard receiver.responds(to: selector) else { return nil }
        return unsafeBitCast(receiver.method(for: selector), to: UInt32Getter.self)(receiver, selector)
    }
}
