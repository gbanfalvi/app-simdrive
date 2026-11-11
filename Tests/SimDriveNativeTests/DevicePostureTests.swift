import Testing
@testable import SimDriveNative

struct DevicePostureTests {
    @Test(arguments: [(0.0, DevicePosture.closed), (14.9, .closed), (130, .partiallyOpen), (175, .partiallyOpen), (175.1, .open)])
    func anglesConfirmPostures(angle: Double, posture: DevicePosture) {
        #expect(DevicePosture(angle: angle) == posture)
    }

    @Test func missingAnglesConfirmNothing() {
        #expect(DevicePosture(angle: nil) == nil)
        #expect(DevicePosture(angle: .nan) == nil)
    }

    @Test func eachPostureConfirmsItsOwnAngle() {
        for posture in DevicePosture.allCases {
            #expect(DevicePosture(angle: posture.degrees) == posture)
        }
    }
}
