import SimDriveNative

/// A screen's interface orientation, as `simctl io enumerate` reports it. `simctl` rotates screenshots by it, and it can
/// differ from the device's orientation when the foreground app does not support that one.
enum InterfaceOrientation: String, Codable, CaseIterable, Sendable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

    /// The interface counter-rotates the device, so UIKit's landscape interface and device names swap.
    var deviceOrientation: DeviceOrientation {
        switch self {
        case .portrait: .portrait
        case .portraitUpsideDown: .portraitUpsideDown
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        }
    }

    /// A label such as `Landscape Left`; nil for `Ambiguous`.
    init?(label: String) {
        let key = label.filter { !$0.isWhitespace }.lowercased()
        guard let orientation = Self.allCases.first(where: { $0.rawValue.lowercased() == key }) else { return nil }
        self = orientation
    }

    /// Each connected screen's orientation in `simctl io <udid> enumerate` output, by screen ID.
    static func parse(enumeration: String) -> [Int: InterfaceOrientation] {
        var orientations: [Int: InterfaceOrientation] = [:]
        for match in enumeration.matches(of: /Screen ID: (\d+)[\s\S]*?UI Orientation: ([^\n]+)/) {
            guard let screen = Int(match.1), let orientation = InterfaceOrientation(label: String(match.2)) else { continue }
            orientations[screen] = orientation
        }
        return orientations
    }
}
