import Testing
@testable import SimDriveCore

@MainActor
struct LazyCapabilityTests {
    private struct Failure: Error {}

    @Test func opensOnce() async throws {
        var opens = 0
        let capability = LazyCapability<Int> {
            opens += 1
            return opens
        }
        #expect(capability.existing == nil)
        #expect(try await capability.value() == 1)
        #expect(try await capability.value() == 1)
        #expect(capability.existing == 1)
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
}
