import Testing
@testable import SimDriveCore
@testable import SimDriveNative

/// `orientation`'s `physical` field keeps the spelling it had as CoreDevice's raw value.
struct PhysicalOrientationTests {
    @Test func uprightUsesCommandNamesAndFlatKeepsCoreDevicesSpelling() {
        #expect(PhysicalOrientation(rawValue: "landscapeLeft").name == "landscape-left")
        #expect(PhysicalOrientation(rawValue: "faceUp") == .faceUp)
        #expect(PhysicalOrientation(rawValue: "faceUp").name == "faceUp")
        #expect(PhysicalOrientation(rawValue: "unknown").name == "unknown")
        #expect(PhysicalOrientation(rawValue: "sideways").name == "sideways")
    }
}
