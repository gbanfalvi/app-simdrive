import Foundation
import SimDriveNative
import Testing
@testable import SimDriveCore

struct StatePathsTests {
    private let parent = FileManager.default.temporaryDirectory.appendingPathComponent("StatePathsTests-\(UUID().uuidString)")

    private func mode(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    @Test func aNewDirectoryIsPrivate() throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("state")
        try StatePaths.prepare(directory)
        #expect(try mode(of: directory) == 0o700)
    }

    @Test func anOwnDirectoryOpenToOthersIsMadePrivate() throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let directory = parent.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o777])
        try StatePaths.prepare(directory)
        #expect(try mode(of: directory) == 0o700)
    }

    @Test func aSymlinkInPlaceOfTheDirectoryIsRefused() throws {
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("elsewhere")
        let directory = parent.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: target)
        let error = #expect(throws: SimDriveError.self) { try StatePaths.prepare(directory) }
        #expect(error?.code == .stateDirectory)
    }
}
