import Darwin
import Foundation

/// Per-user files: each device's daemon socket and log, screenshot records, calibration image and log cursors.
enum StatePaths {
    /// Unix socket paths are limited to 104 bytes, which `$TMPDIR` plus a UDID can exceed.
    static let directory = URL(fileURLWithPath: "/tmp/simdrive-\(getuid())", isDirectory: true)
    private static let privateDirectoryMode = 0o700

    static func socket(for udid: String) -> URL { directory.appendingPathComponent("\(udid).sock") }
    static func log(for udid: String) -> URL { directory.appendingPathComponent("\(udid).log") }
    /// Held by the device's daemon for its whole life, so only one serves a device.
    static func daemonLock(for udid: String) -> URL { directory.appendingPathComponent("\(udid).daemon.lock") }
    static func screens(for udid: String) -> URL { directory.appendingPathComponent("\(udid).screens.json") }
    static func calibration(for udid: String) -> URL { directory.appendingPathComponent("\(udid).calibration.png") }
    static func logCursors(for udid: String) -> URL { directory.appendingPathComponent("\(udid).logs.json") }

    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: privateDirectoryMode])
    }
}
