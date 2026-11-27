import Darwin
import Foundation
import SimDriveNative

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
    /// A physical device's crash reports, copied off it as `logs` reads them.
    static func crashReports(for udid: String) -> URL { directory.appendingPathComponent("\(udid).crashes", isDirectory: true) }
    /// A physical device's launched app's stdout and stderr, which `devicectl --console` relays to the Mac.
    static func appOutput(for udid: String) -> URL { directory.appendingPathComponent("\(udid).output", isDirectory: true) }
    /// `devicectl`'s own messages while it relays that output, which it also writes to the app's stdout.
    static func consoleLog(for udid: String) -> URL { appOutput(for: udid).appendingPathComponent("devicectl.txt") }

    /// Creates the directory, or checks the one there. Its name is predictable in a directory every user can write to,
    /// so another user could create it first and redirect the socket, the log or the records written into it.
    static func prepare() throws {
        try prepare(directory)
    }

    static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: privateDirectoryMode])
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid() else {
            throw SimDriveError(.stateDirectory, "\(directory.path) is not a directory of your own; remove it, then retry.")
        }
        if status.st_mode & 0o077 != 0, chmod(directory.path, mode_t(privateDirectoryMode)) != 0 {
            throw SimDriveError(.stateDirectory, "\(directory.path) is open to other users and could not be made private.")
        }
    }
}
