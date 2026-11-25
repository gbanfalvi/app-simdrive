import Testing
@testable import SimDriveNative

struct ScreenAdapterTests {
    /// Measured on a cold iPhone boot, iOS 27.2: every screen reads -101 until the main panel reports 2, about 85 s in.
    @Test func aScreenHasStartedOnceAnyReportsAKnownBacklight() {
        #expect(!ScreenAdapter.hasStartedScreen(backlightStates: [-101, -101, -101]))
        #expect(ScreenAdapter.hasStartedScreen(backlightStates: [2, -101, -101]))
    }

    /// The Duo's inner panel reads -101 even when settled, while its cover panel reports a state.
    @Test func onePanelWithAKnownStateIsEnough() {
        #expect(ScreenAdapter.hasStartedScreen(backlightStates: [2, -101, -101, -101, -101]))
    }

    /// CoreSimulator's states, as NeoSimulator documents them and an iPhone on iOS 27.2 reported 2 and -101.
    @Test func backlightStatesNameTheirLevel() {
        #expect([2, 1, 0, -101, 7].map(Backlight.init(state:)) == [.on, .dimmed, .off, .unknown, .unknown])
    }

    @Test func aRuntimeThatReportsNoBacklightCountsAsStarted() {
        #expect(ScreenAdapter.hasStartedScreen(backlightStates: [nil, nil]))
        #expect(ScreenAdapter.hasStartedScreen(backlightStates: []))
    }
}
