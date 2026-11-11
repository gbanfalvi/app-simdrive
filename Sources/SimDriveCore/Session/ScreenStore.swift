import Foundation
import SimDriveNative

/// A screen's last screenshot, which pixel coordinates and the screen's rotation refer to.
struct ScreenRecord: Codable, Equatable, Sendable {
    let full: PixelSize
    /// The image the caller reads, which may be downscaled.
    let image: PixelSize
    let orientation: DeviceOrientation
}

extension ScreenRecord {
    init(_ shot: Screenshot, orientation: DeviceOrientation) {
        self.init(full: shot.full, image: shot.image, orientation: orientation)
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
