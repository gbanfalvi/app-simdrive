import Testing
@testable import SimDriveCore

struct DeviceAppsTests {
    /// As `simctl spawn <udid> launchctl list` printed on iOS 27.2.
    private static let jobs = """
        PID\tStatus\tLabel
        16096\t0\tUIKitApplication:com.simdrive.axprobe[3c1f][rb-legacy]
        -\t0\tUIKitApplication:com.apple.Preferences[8a2e][rb-legacy]
        412\t0\tcom.apple.SpringBoard
        """

    @Test func aRunningAppsPidComesFromItsJob() {
        #expect(DeviceApps.runningProcess(of: "com.simdrive.axprobe", inLaunchctlList: Self.jobs) == 16096)
    }

    @Test func anAppThatIsNotRunningHasNoPid() {
        #expect(DeviceApps.runningProcess(of: "com.apple.Preferences", inLaunchctlList: Self.jobs) == nil)
        #expect(DeviceApps.runningProcess(of: "com.simdrive", inLaunchctlList: Self.jobs) == nil)
    }
}
