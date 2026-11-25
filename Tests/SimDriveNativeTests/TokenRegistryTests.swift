import Testing
@testable import SimDriveNative

struct TokenRegistryTests {
    /// A session opened after a reboot registers the same device token; the old session closing afterwards must not
    /// remove the new session's route (F24).
    @Test func aReplacedValueOutlivesItsPredecessorsRemoval() {
        let registry = TokenRegistry<Int>()
        registry.register(1, for: "device")
        registry.register(2, for: "device")
        registry.remove("device") { $0 == 1 }
        #expect(registry.value(for: "device") == 2)
        registry.remove("device") { $0 == 2 }
        #expect(registry.value(for: "device") == nil)
        #expect(registry.value(for: "unknown") == nil)
    }

    /// `translationApplicationObjectForPid:` asks with no token; only a single session can answer for it.
    @Test func aCallbackWithoutTokenGoesToTheOnlyValue() {
        let registry = TokenRegistry<Int>()
        #expect(registry.onlyValue == nil)
        registry.register(1, for: "one")
        #expect(registry.onlyValue == 1)
        registry.register(2, for: "two")
        #expect(registry.onlyValue == nil)
    }
}
