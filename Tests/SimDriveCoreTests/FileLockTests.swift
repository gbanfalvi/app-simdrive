import Foundation
import Testing
@testable import SimDriveCore

struct FileLockTests {
    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("FileLockTests-\(UUID().uuidString).lock")

    /// `flock` locks belong to an open file, so a second open in the same process stands in for a second daemon.
    @Test func onlyTheFirstHolderKeepsTheLock() {
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileLock(url: url).holdForLife())
        #expect(!FileLock(url: url).holdForLife())
    }

    @Test func aHeldLifetimeLockKeepsOthersFromTakingIt() {
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FileLock(url: url).holdForLife())
        let other = open(url.path, O_RDWR)
        defer { close(other) }
        #expect(flock(other, LOCK_EX | LOCK_NB) != 0)
    }
}
