import CoreGraphics
import Testing
@testable import SimDriveCore

struct SplitGestureTests {
    @Test func noGestureWithinALayout() {
        for layout in SplitLayout.allCases {
            #expect(SplitGesture.moving(from: layout, to: layout) == nil)
        }
    }

    @Test func leftGesturesMirrorRightOnes() throws {
        let pairs: [((SplitLayout, SplitLayout), (SplitLayout, SplitLayout))] = [
            ((.full, .right), (.full, .left)), ((.right, .full), (.left, .full)), ((.right, .left), (.left, .right)),
        ]
        for ((rightFrom, rightTo), (leftFrom, leftTo)) in pairs {
            let right = try #require(SplitGesture.moving(from: rightFrom, to: rightTo))
            let left = try #require(SplitGesture.moving(from: leftFrom, to: leftTo))
            #expect(left.path == right.path.map { CGPoint(x: 1 - $0.x, y: $0.y) })
            #expect(left.duration == right.duration)
        }
    }

    @Test func gesturesGrabTheAppsHomeIndicator() throws {
        let grabs: [(SplitLayout, CGFloat)] = [(.full, 0.5), (.right, 0.75), (.left, 0.25)]
        for (from, x) in grabs {
            for to in SplitLayout.allCases where to != from {
                #expect(try #require(SplitGesture.moving(from: from, to: to)).path.first?.x == x)
            }
        }
    }
}
