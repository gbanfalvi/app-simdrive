import SimDriveNative
import Testing
@testable import SimDriveCore

@MainActor
struct LazyCapabilityTests {
    private struct Failure: Error {}

    private final class Service {
        let number: Int
        var isUsable = true
        var isClosed = false

        init(_ number: Int) {
            self.number = number
        }
    }

    @Test func opensOnce() async throws {
        var opens = 0
        let capability = LazyCapability<Int> {
            opens += 1
            return opens
        }
        #expect(try await capability.value() == 1)
        #expect(try await capability.value() == 1)
        #expect(opens == 1)
    }

    @Test func remembersThatTheDeviceLacksIt() async throws {
        var opens = 0
        let capability = LazyCapability<Int> {
            opens += 1
            return nil
        }
        #expect(try await capability.value() == nil)
        #expect(try await capability.value() == nil)
        await capability.close()
        #expect(try await capability.value() == nil)
        #expect(opens == 1)
    }

    @Test func retriesAfterAFailure() async throws {
        var fails = true
        let capability = LazyCapability<Int> {
            if fails {
                fails = false
                throw Failure()
            }
            return 1
        }
        await #expect(throws: Failure.self) { try await capability.value() }
        #expect(try await capability.value() == 1)
    }

    @Test func reopensAServiceThatIsNoLongerUsable() async throws {
        var opens = 0
        let capability = LazyCapability<Service>(isUsable: { $0.isUsable }) {
            opens += 1
            return Service(opens)
        }
        let first = try #require(try await capability.value())
        first.isUsable = false
        #expect(try await capability.value()?.number == 2)
        #expect(try await capability.value()?.number == 2)
    }

    @Test func closingReleasesTheServiceUntilTheNextUse() async throws {
        var opens = 0
        let capability = LazyCapability<Service>(close: { $0.isClosed = true }) {
            opens += 1
            return Service(opens)
        }
        await capability.close()
        let first = try #require(try await capability.value())
        await capability.close()
        #expect(first.isClosed)
        #expect(try await capability.value()?.number == 2)
    }

    @Test func requiredThrowsWhenTheDeviceLacksIt() async throws {
        let capability = LazyCapability<Int> { nil }
        await #expect(throws: SimDriveError.self) {
            try await capability.required(orThrow: SimDriveError(.pasteboardUnsupported, "No pasteboard."))
        }
    }
}
