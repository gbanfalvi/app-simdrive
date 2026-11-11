import Testing
@testable import SimDriveNative

struct GuestInputTests {
    @Test func buttonUsagesAreDistinct() {
        #expect(Set(HardwareButton.allCases.map(\.usage)).count == HardwareButton.allCases.count)
    }

    @Test func digitizerTargetsNameTheirCoreDeviceCase() {
        #expect(DigitizerTarget.mainScreen.description == "mainScreen")
        #expect(DigitizerTarget.display(3).description == "display3")
    }
}
