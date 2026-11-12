import Testing
@testable import SimDriveNative

struct InterfaceOrientationTests {
    @Test func readsCoreSimulatorValuesAsSimctlLabelsThem() {
        #expect(InterfaceOrientation(screenValue: 1) == .portrait)
        #expect(InterfaceOrientation(screenValue: 2) == .portraitUpsideDown)
        #expect(InterfaceOrientation(screenValue: 3) == .landscapeLeft)
        #expect(InterfaceOrientation(screenValue: 4) == .landscapeRight)
    }

    @Test func ambiguousAndUnknownValuesHaveNoOrientation() {
        #expect(InterfaceOrientation(screenValue: 0) == nil)
        #expect(InterfaceOrientation(screenValue: 5) == nil)
    }

    @Test func landscapeInterfacesMatchTheOppositeDeviceOrientation() {
        #expect(InterfaceOrientation.landscapeLeft.deviceOrientation == .landscapeRight)
        #expect(InterfaceOrientation.landscapeRight.deviceOrientation == .landscapeLeft)
        #expect(InterfaceOrientation.portraitUpsideDown.deviceOrientation == .portraitUpsideDown)
    }
}
