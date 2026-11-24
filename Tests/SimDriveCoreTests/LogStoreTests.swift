import Foundation
import Testing
@testable import SimDriveCore

struct LogStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LogStoreTests-\(UUID().uuidString)")

    private func store() throws -> LogStore {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return LogStore(url: directory.appendingPathComponent("logs.json"))
    }

    private static func app(_ bundleID: String, launchedAt seconds: TimeInterval) -> LogStore.App {
        LogStore.App(bundleID: bundleID, pid: 1, launchedAt: Date(timeIntervalSince1970: seconds), stdoutPath: "/tmp/out",
                     stderrPath: "/tmp/err")
    }

    @Test func aWriteForTheLatestLaunchApplies() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store()
        let first = Self.app("com.example.first", launchedAt: 100)
        store.update { $0 = LogStore.Contents(app: first) }
        let applied = store.update(forLaunchAt: first.launchedAt) { $0.cursors["default"] = LogStore.Cursor(date: .now, stdoutOffset: 42) }
        #expect(applied)
        #expect(store.read().cursors["default"]?.stdoutOffset == 42)
    }

    @Test func aWriteReadBeforeALaunchLeavesTheNewLaunchAlone() throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try store()
        let first = Self.app("com.example.first", launchedAt: 100)
        let second = Self.app("com.example.second", launchedAt: 200)
        store.update { $0 = LogStore.Contents(app: first) }
        let readFor = store.read().app?.launchedAt
        store.update { $0 = LogStore.Contents(app: second) }
        let applied = store.update(forLaunchAt: readFor) { contents in
            contents.cursors["default"] = LogStore.Cursor(date: .now, stdoutOffset: 42)
            contents.app?.process = "First"
        }
        #expect(!applied)
        #expect(store.read() == LogStore.Contents(app: second))
    }
}
