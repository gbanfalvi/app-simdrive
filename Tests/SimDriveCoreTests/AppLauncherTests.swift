import Testing
@testable import SimDriveCore

struct AppLauncherTests {
    @Test func pidComesFromSimctlLaunchOutput() {
        #expect(AppLauncher.pid(fromLaunchOutput: "com.simdrive.axprobe: 4321\n") == 4321)
        #expect(AppLauncher.pid(fromLaunchOutput: "") == nil)
        #expect(AppLauncher.pid(fromLaunchOutput: "An error was encountered processing the command") == nil)
    }
}
