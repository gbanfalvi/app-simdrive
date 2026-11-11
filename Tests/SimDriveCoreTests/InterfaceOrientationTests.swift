import SimDriveNative
import Testing
@testable import SimDriveCore

struct InterfaceOrientationTests {
    private let enumeration = """
        Port:
            UUID: 1339073C-BDC0-4084-9E41-C5D279D827AF
            Class: DisplayAdapter
            Connected Screens:
            (1) LCD:
                Screen ID: 1
                Pixel Size: {1398, 2034}
                UI Orientation: Portrait
            (2) TVOut:
                Screen ID: 2
                Pixel Size: {720, 480}
                UI Orientation: Ambiguous
            (3) LCD-1:
                Screen ID: 3
                Pixel Size: {2007, 2853}
                UI Orientation: Landscape Left
        """

    @Test func parsesEachScreenAndSkipsAmbiguousOnes() {
        #expect(InterfaceOrientation.parse(enumeration: enumeration) == [1: .portrait, 3: .landscapeLeft])
    }

    @Test func readsSimctlLabels() {
        #expect(InterfaceOrientation(label: "Landscape Right") == .landscapeRight)
        #expect(InterfaceOrientation(label: "Portrait Upside Down") == .portraitUpsideDown)
        #expect(InterfaceOrientation(label: "Ambiguous") == nil)
    }

    @Test func landscapeInterfacesMatchTheOppositeDeviceOrientation() {
        #expect(InterfaceOrientation.landscapeLeft.deviceOrientation == .landscapeRight)
        #expect(InterfaceOrientation.landscapeRight.deviceOrientation == .landscapeLeft)
        #expect(InterfaceOrientation.portraitUpsideDown.deviceOrientation == .portraitUpsideDown)
    }
}
