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

    /// The Duo's inner panel keeps a Landscape Left interface while the device turns landscape-left.
    @Test func theInterfaceOrientationOverridesTheDevices() {
        let mapping = ScreenMapping(screenshot: record(width: 2853, height: 2007, interface: .landscapeLeft),
                                    panelIsLandscape: false, deviceOrientation: .landscapeLeft)
        #expect(mapping.digitizerPoint(point) == CGPoint(x: 0.75, y: 0.75))
    }

    @Test func aPortraitOnlyAppStaysUnflippedOnAnUpsideDownDevice() {
        let mapping = ScreenMapping(screenshot: record(width: 1206, height: 2622, interface: .portrait),
                                    panelIsLandscape: false, deviceOrientation: .portraitUpsideDown)
        #expect(mapping.digitizerPoint(point) == point)
    }

    @Test func anUnknownInterfaceFallsBackToTheDevice() {
        let mapping = ScreenMapping(screenshot: record(width: 2622, height: 1206, interface: nil),
                                    panelIsLandscape: false, deviceOrientation: .landscapeLeft)
        #expect(mapping == ScreenMapping(isRotated: true, orientation: .landscapeLeft))
    }

    @Test func edgesFollowTheRotation() {
        #expect(ScreenMapping(isRotated: false, orientation: .portrait).digitizerEdge(.bottom) == .bottom)
        #expect(ScreenMapping(isRotated: false, orientation: .portraitUpsideDown).digitizerEdge(.bottom) == .top)
        #expect(ScreenMapping(isRotated: true, orientation: .landscapeLeft).digitizerEdge(.bottom) == .left)
        #expect(ScreenMapping(isRotated: true, orientation: .portrait).digitizerEdge(.bottom) == .right)
        #expect(ScreenMapping(isRotated: true, orientation: .portrait).digitizerEdge(.left) == .bottom)
    }

    private func record(width: Int, height: Int, interface: InterfaceOrientation?) -> ScreenRecord {
        let size = PixelSize(width: width, height: height)
        return ScreenRecord(full: size, image: size, orientation: .portrait, interfaceOrientation: interface)
    }
}
