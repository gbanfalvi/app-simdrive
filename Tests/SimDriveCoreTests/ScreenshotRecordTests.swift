import SimDriveNative
import Testing
@testable import SimDriveCore

struct ScreenshotRecordTests {
    private static func record(_ interface: InterfaceOrientation?) -> ScreenshotRecord {
        let size = PixelSize(width: 1000, height: 2000)
        return ScreenshotRecord(full: size, image: size, orientation: .portrait, interfaceOrientation: interface)
    }

    @Test func anUnchangedScreenIsCurrent() {
        #expect(Self.record(.portrait).isCurrent(deviceOrientation: .portrait, interfaceOrientation: .portrait))
    }

    @Test func aRotatedDeviceMakesItStale() {
        #expect(!Self.record(.portrait).isCurrent(deviceOrientation: .landscapeLeft, interfaceOrientation: .portrait))
    }

    /// A landscape-only app opened on an upright phone turns the interface alone.
    @Test func anInterfaceThatTurnedAloneMakesItStale() {
        #expect(!Self.record(.portrait).isCurrent(deviceOrientation: .portrait, interfaceOrientation: .landscapeRight))
    }

    @Test func anUnreadableInterfaceIsNotCompared() {
        #expect(Self.record(nil).isCurrent(deviceOrientation: .portrait, interfaceOrientation: .landscapeRight))
        #expect(Self.record(.portrait).isCurrent(deviceOrientation: .portrait, interfaceOrientation: nil))
    }
}
