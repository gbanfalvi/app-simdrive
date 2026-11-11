import SimDriveNative
import Testing
@testable import SimDriveCore

struct SimulatorDisplayTests {
    private let listing = """
        An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=22):
        Cannot choose between 2 displays. Specify one with --display:
            --display=3  LCD-1 (primary-1) 2007x2853
            --display=1  LCD (primary) 1398x2034
        Invalid argument
        """

    @Test func parsesTheSimctlListingByIndex() {
        let displays = SimulatorDisplay.parse(listing: listing)
        #expect(displays.map(\.index) == [1, 3])
        #expect(displays.map(\.role) == [SimulatorDisplay.coverRole, SimulatorDisplay.innerRole])
        #expect(displays[1].name == "LCD-1")
        #expect(displays[1].digitizerTarget == .display(3))
        #expect(displays[1].nativeSize == PixelSize(width: 2007, height: 2853))
        #expect(!displays[1].nativeSize.isLandscape)
    }

    @Test func selectorNames() {
        #expect(DisplaySelector(name: "inner") == .inner)
        #expect(DisplaySelector(name: "2") == .index(2))
        #expect(DisplaySelector(name: "side") == nil)
    }
}
