import Testing
@testable import SimDriveCore

struct StillnessTests {
    private static let gray: [UInt8] = [100, 100, 100, 255, 100, 100, 100, 255]
    private static let lighter: [UInt8] = [100, 100, 100, 255, 110, 100, 100, 255]

    /// Whether each sample, taken at its time in milliseconds, finds the pixels still for 150 ms.
    private static func verdicts(_ samples: [([UInt8], Int)]) -> [Bool] {
        var stillness = Stillness(stillFor: .milliseconds(150))
        return samples.map { stillness.isStill(after: $0.0, at: .milliseconds($0.1)) }
    }

    /// The URL alert's region was still for ~120 ms before its first frame drew, so a still run must count from its start.
    @Test func stillOnceUnchangedForTheWholeSpan() {
        #expect(Self.verdicts([(Self.gray, 0), (Self.gray, 100), (Self.gray, 150)]) == [false, false, true])
    }

    /// The alert's last 200 ms changed only a few percent of its pixels per sample; each change restarts the span.
    @Test func aChangeRestartsTheSpan() {
        #expect(Self.verdicts([(Self.gray, 0), (Self.lighter, 140), (Self.lighter, 280), (Self.lighter, 290)])
                == [false, false, false, true])
    }

    @Test func changesWithinTheToleranceDoNotCount() {
        let nudged: [UInt8] = [102, 102, 102, 255, 100, 100, 100, 0]
        #expect(!Stillness.differs(Self.gray, nudged))
        #expect(Stillness.differs(Self.gray, Self.lighter))
    }

    /// A clipped patch changes size only if the point moved, which counts as a change.
    @Test func samplesOfDifferentSizesDiffer() {
        #expect(Stillness.differs(Self.gray, Array(Self.gray.prefix(4))))
    }
}
