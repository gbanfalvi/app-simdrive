import Foundation

/// One panel of a multi-display simulator, as `simctl io screenshot` lists it.
package struct DisplayInfo: Equatable, Sendable {
    /// `simctl` names a foldable's cover panel `primary` and its inner panel `primary-1`.
    static let coverRole = "primary"
    static let innerRole = "primary-1"

    package let index: Int
    package let name: String
    package let role: String
    package let nativeWidth: Int
    package let nativeHeight: Int

    package var isNativeLandscape: Bool { nativeWidth > nativeHeight }
    /// The CoreDevice `DigitizerTarget` case of the panel, which matches `simctl`'s display index.
    package var digitizerTarget: String { "display\(index)" }

    package var json: JSONValue {
        ["index": .number(Double(index)), "name": .string(name), "role": .string(role),
         "width": .number(Double(nativeWidth)), "height": .number(Double(nativeHeight))]
    }

    /// The displays that `simctl io screenshot` lists when a multi-display device needs `--display`.
    package static func parse(listing: String) -> [DisplayInfo] {
        listing.matches(of: /--display=(\d+)\s+(.+?)\s+\(([^)]+)\)\s+(\d+)x(\d+)/).compactMap { match in
            guard let index = Int(match.1), let width = Int(match.4), let height = Int(match.5) else { return nil }
            return DisplayInfo(index: index, name: String(match.2), role: String(match.3), nativeWidth: width, nativeHeight: height)
        }.sorted { $0.index < $1.index }
    }
}

/// Which panel a command addresses.
package enum DisplaySelector: Equatable, Sendable {
    /// The single screen, or a foldable's panel for its posture.
    case automatic
    case cover
    case inner
    case index(Int)

    package init?(name: String) {
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
