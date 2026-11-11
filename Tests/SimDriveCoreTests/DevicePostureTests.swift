import SimDriveNative
import Testing

struct DevicePostureTests {
    @Test(arguments: [(0.0, DevicePosture.closed), (14.9, .closed), (130, .partiallyOpen), (175, .partiallyOpen), (175.1, .open)])
    func anglesConfirmPostures(angle: Double, posture: DevicePosture) {
        #expect(DevicePosture.confirmed(angle: angle) == posture)
    }

    @Test func missingAnglesConfirmNothing() {
        #expect(DevicePosture.confirmed(angle: nil) == nil)
        #expect(DevicePosture.confirmed(angle: .nan) == nil)
    }
}
