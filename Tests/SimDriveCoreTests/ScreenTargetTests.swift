import CoreGraphics
import SimDriveNative
import Testing
@testable import SimDriveCore

struct ScreenTargetTests {
    private let target = ScreenTargets.Target(display: nil,
        record: ScreenRecord(full: PixelSize(width: 2000, height: 4000), image: PixelSize(width: 500, height: 1000), orientation: .portrait),
        mapping: ScreenMapping(isRotated: false, orientation: .portrait))

    @Test func pixelsReferToTheDownscaledImage() {
        #expect(target.normalizedPoint(.pixels(CGPoint(x: 125, y: 250))) == CGPoint(x: 0.25, y: 0.25))
    }

    @Test func pointsOutsideTheScreenAreClamped() {
        #expect(target.normalizedPoint(.pixels(CGPoint(x: 600, y: 2000))) == CGPoint(x: 1, y: 1))
    }

    @Test func singleScreensTargetTheMainScreen() {
        #expect(target.digitizerTarget == .mainScreen)
    }
}
