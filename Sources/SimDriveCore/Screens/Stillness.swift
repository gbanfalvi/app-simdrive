import Foundation

/// Whether samples of the same pixels have stopped changing. UIKit ignores touches while a transition animates, though
/// the accessibility tree places the element finally from the start (F29 in `roadmap/backlog.md`,
/// `docs/device-behavior.md`), so an element tap waits for the pixels under its point to hold still.
struct Stillness {
    /// The summed change of blue, green and red at which a pixel counts as changed, above compression-free noise.
    static let tolerance = 6

    let stillFor: Duration
    private var last: [UInt8]?
    private var unchangedSince: Duration = .zero

    init(stillFor: Duration) {
        self.stillFor = stillFor
    }

    /// Adds a sample taken `time` after the first; true once the samples have not changed for `stillFor`.
    mutating func isStill(after sample: [UInt8], at time: Duration) -> Bool {
        if last.map({ Self.differs($0, sample) }) ?? true {
            unchangedSince = time
        }
        last = sample
        return time - unchangedSince >= stillFor
    }

    /// Samples of BGRA pixels differ when their sizes do or any pixel changed by more than `tolerance`.
    static func differs(_ first: [UInt8], _ second: [UInt8]) -> Bool {
        guard first.count == second.count else { return true }
        return stride(from: 0, to: first.count - 3, by: 4).contains { index in
            abs(Int(first[index]) - Int(second[index])) + abs(Int(first[index + 1]) - Int(second[index + 1]))
                + abs(Int(first[index + 2]) - Int(second[index + 2])) > tolerance
        }
    }
}
