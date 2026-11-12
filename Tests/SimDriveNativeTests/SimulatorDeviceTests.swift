import Testing
@testable import SimDriveNative

@MainActor
struct SimulatorDeviceTests {
    @Test func majorVersionsComeFromTheRuntimeIdentifier() {
        #expect(SimulatorDevice.majorOSVersion(ofRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-18-3") == 18)
        #expect(SimulatorDevice.majorOSVersion(ofRuntime: "com.apple.CoreSimulator.SimRuntime.tvOS-26-2") == 26)
        #expect(SimulatorDevice.majorOSVersion(ofRuntime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4") == 27)
        #expect(SimulatorDevice.majorOSVersion(ofRuntime: "com.apple.CoreSimulator.SimRuntime.unknown") == nil)
    }
}
