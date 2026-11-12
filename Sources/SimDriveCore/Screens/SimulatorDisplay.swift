import SimDriveNative

/// One panel of a multi-display simulator, as `simctl io screenshot` lists it.
struct SimulatorDisplay: Codable, Equatable, Sendable {
    /// `simctl` names a foldable's cover panel `primary` and its inner panel `primary-1`.
    static let coverRole = "primary"
    static let innerRole = "primary-1"

    let index: Int
    let name: String
    let role: String
    let nativeSize: PixelSize

    /// The displays that `simctl io screenshot` lists when a multi-display device needs `--display`.
    static func parse(listing: String) -> [SimulatorDisplay] {
        listing.matches(of: /--display=(\d+)\s+(.+?)\s+\(([^)]+)\)\s+(\d+)x(\d+)/).compactMap { match in
            guard let index = Int(match.1), let width = Int(match.4), let height = Int(match.5) else { return nil }
            return SimulatorDisplay(index: index, name: String(match.2), role: String(match.3),
                                    nativeSize: PixelSize(width: width, height: height))
        }.sorted { $0.index < $1.index }
    }
}

extension DigitizerTarget {
    /// A single-display device has no display to name.
    init(display: SimulatorDisplay?) {
        self = display.map { .display($0.index) } ?? .mainScreen
    }
}

/// Which panel a command addresses.
enum DisplaySelector: Equatable, Sendable {
    /// The single screen, or a foldable's panel for its posture.
    case automatic
    case cover
    case inner
    case index(Int)

    init?(name: String) {
        switch name.lowercased() {
        case "auto", "automatic": self = .automatic
        case "cover": self = .cover
        case "inner": self = .inner
        default:
            guard let index = Int(name) else { return nil }
            self = .index(index)
        }
    }
}
