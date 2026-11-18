import CoreGraphics
import Testing
@testable import SimDriveCore

struct TwoFingerGestureTests {
    private static let screen = CGSize(width: 1000, height: 2000)
    private static let center = CGPoint(x: 0.5, y: 0.5)

    @Test func pinchSpreadsFingersByTheScaleOnAHorizontalLine() {
        let gesture = TwoFingerGesture.pinch(around: Self.center, scale: 2, screen: Self.screen)
        #expect(gesture.first.map(\.x) == [0.65, 0.8])
        #expect(gesture.second.map(\.x) == [0.35, 0.2])
        #expect(gesture.first.allSatisfy { $0.y == 0.5 })
    }

    @Test func pinchBelowOneCloses() {
        let gesture = TwoFingerGesture.pinch(around: Self.center, scale: 0.5, screen: Self.screen)
        #expect(gesture.first.map(\.x) == [0.8, 0.65])
    }

    @Test func rotationTurnsClockwiseInScreenPixels() {
        let gesture = TwoFingerGesture.rotation(around: Self.center, degrees: 90, screen: Self.screen)
        #expect(gesture.first.count == 10)
        let end = gesture.first[gesture.first.count - 1]
        #expect(abs(end.x - 0.5) < 1e-9)
        #expect(abs(end.y - 0.6) < 1e-9)
        let opposite = gesture.second[gesture.second.count - 1]
        #expect(abs(opposite.y - 0.4) < 1e-9)
    }
}
