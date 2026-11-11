import Foundation
import SimDriveNative

/// A screen's last screenshot, which pixel coordinates and the screen's rotation refer to.
struct ScreenRecord: Codable, Equatable, Sendable {
    let full: PixelSize
    /// The image the caller reads, which may be downscaled.
    let image: PixelSize
    let orientation: DeviceOrientation
    /// The interface's orientation at capture, which the screenshot is rotated by; nil when `simctl` reports none.
    let interfaceOrientation: InterfaceOrientation?
}

extension ScreenRecord {
    init(_ shot: Screenshot, orientation: DeviceOrientation, interfaceOrientation: InterfaceOrientation?) {
        self.init(full: shot.full, image: shot.image, orientation: orientation, interfaceOrientation: interfaceOrientation)
    }
}

/// Each screen's last screenshot record, kept in a file so one-shot runs share them.
@MainActor
final class ScreenStore {
    private let url: URL
    private var records: [String: ScreenRecord]

    init(url: URL) {
        self.url = url
        records = (try? JSONDecoder().decode([String: ScreenRecord].self, from: Data(contentsOf: url))) ?? [:]
    }

    func record(for target: DigitizerTarget) -> ScreenRecord? { records[target.description] }

    func save(_ record: ScreenRecord, for target: DigitizerTarget) {
        records[target.description] = record
        persist()
    }

    func removeAll() {
        records = [:]
        persist()
    }

    private func persist() {
        try? JSONEncoder.line.encode(records).write(to: url, options: .atomic)
    }
}
