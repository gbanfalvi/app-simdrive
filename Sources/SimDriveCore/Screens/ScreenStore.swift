import Foundation
import SimDriveNative

/// A screen's last screenshot, which pixel coordinates and the screen's rotation refer to.
struct ScreenshotRecord: Codable, Equatable, Sendable {
    let full: PixelSize
    /// The image the caller reads, which may be downscaled.
    let image: PixelSize
    let orientation: DeviceOrientation
    /// The interface's orientation at capture, which the screenshot is rotated by; nil when CoreSimulator reports none.
    let interfaceOrientation: InterfaceOrientation?
}

extension ScreenshotRecord {
    init(_ shot: Screenshot, orientation: DeviceOrientation, interfaceOrientation: InterfaceOrientation?) {
        self.init(full: shot.full, image: shot.image, orientation: orientation, interfaceOrientation: interfaceOrientation)
    }
}

/// The device's displays and each screen's last screenshot record, kept in a file so one-shot runs share them. A reboot
/// discards both.
@MainActor
final class ScreenStore {
    private struct Contents: Codable {
        var bootedAt: Date?
        /// Empty for a single-display device; nil until listed.
        var displays: [SimulatorDisplay]?
        /// By digitizer target, such as `mainScreen` or `display3`.
        var records: [String: ScreenshotRecord] = [:]
    }

    /// Boot dates survive the file's round trip to within a fraction of a second.
    private static let bootDateTolerance: TimeInterval = 1

    private let url: URL
    private var contents: Contents

    init(url: URL, bootedAt: Date?) {
        self.url = url
        let stored = try? JSONDecoder().decode(Contents.self, from: Data(contentsOf: url))
        contents = stored.flatMap { Self.isSameBoot($0.bootedAt, bootedAt) ? $0 : nil } ?? Contents(bootedAt: bootedAt)
    }

    var displays: [SimulatorDisplay]? {
        get { contents.displays }
        set {
            contents.displays = newValue
            persist()
        }
    }

    func record(for target: DigitizerTarget) -> ScreenshotRecord? { contents.records[target.description] }

    func save(_ record: ScreenshotRecord, for target: DigitizerTarget) {
        contents.records[target.description] = record
        persist()
    }

    func removeRecords() {
        contents.records = [:]
        persist()
    }

    private func persist() {
        try? JSONEncoder.line.encode(contents).write(to: url, options: .atomic)
    }

    private static func isSameBoot(_ stored: Date?, _ current: Date?) -> Bool {
        guard let stored, let current else { return stored == current }
        return abs(stored.timeIntervalSince(current)) < bootDateTolerance
    }
}
