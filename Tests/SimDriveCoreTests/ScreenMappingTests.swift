import CoreGraphics
import SimDriveNative
import Testing
@testable import SimDriveCore

struct ScreenMappingTests {
    private let point = CGPoint(x: 0.25, y: 0.75)

    @Test func unrotatedScreensKeepTheirPoints() {
        #expect(ScreenMapping(isRotated: false, orientation: .portrait).digitizerPoint(point) == point)
        #expect(ScreenMapping(isRotated: false, orientation: .landscapeLeft).digitizerPoint(point) == point)
    }

    @Test func upsideDownFlipsBothAxes() {
        #expect(ScreenMapping(isRotated: false, orientation: .portraitUpsideDown).digitizerPoint(point) == CGPoint(x: 0.75, y: 0.25))
    }

    @Test func landscapeLeftTurnsCounterclockwise() {
        #expect(ScreenMapping(isRotated: true, orientation: .landscapeLeft).digitizerPoint(point) == CGPoint(x: 0.25, y: 0.25))
    }

    /// The Duo's inner panel reads portrait while its screenshots are landscape.
    @Test(arguments: [DeviceOrientation.landscapeRight, .portrait])
    func otherRotationsTurnClockwise(orientation: DeviceOrientation) {
        #expect(ScreenMapping(isRotated: true, orientation: orientation).digitizerPoint(point) == CGPoint(x: 0.75, y: 0.75))
    }

    @Test func edgesFollowTheRotation() {
        #expect(ScreenMapping(isRotated: false, orientation: .portrait).digitizerEdge(.bottom) == .bottom)
        #expect(ScreenMapping(isRotated: false, orientation: .portraitUpsideDown).digitizerEdge(.bottom) == .top)
        #expect(ScreenMapping(isRotated: true, orientation: .landscapeLeft).digitizerEdge(.bottom) == .left)
        #expect(ScreenMapping(isRotated: true, orientation: .portrait).digitizerEdge(.bottom) == .right)
        #expect(ScreenMapping(isRotated: true, orientation: .portrait).digitizerEdge(.left) == .bottom)
    }
}
