import SimDriveNative
import Testing
@testable import SimDriveCore

struct DisplayWakeTests {
    /// Only a dimmed or sleeping display drops input; an unknown state, as before the screen starts, is left be (I6).
    @Test func wakesOnlyDimmedOrSleepingDisplays() {
        #expect(DisplayWake.needsWake(.dimmed))
        #expect(DisplayWake.needsWake(.off))
        #expect(!DisplayWake.needsWake(.on))
        #expect(!DisplayWake.needsWake(.unknown))
        #expect(!DisplayWake.needsWake(nil))
    }

    /// A result says it woke the display only when it did, and keeps its other fields.
    @MainActor @Test func resultsSayWhenTheyWoke() {
        let result: JSONValue = ["display": .null]
        #expect(DeviceSession.noting(woke: false, in: result) == result)
        #expect(DeviceSession.noting(woke: true, in: result) == ["display": .null, "woke": true])
    }
}
