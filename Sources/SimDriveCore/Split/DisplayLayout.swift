import CoreGraphics
import Foundation

/// A layout SpringBoard published for a display, decoded from the message its `DisplayLayout` category logs.
struct DisplayLayout: Equatable {
    static let subsystem = "com.apple.SpringBoard"
    static let category = "DisplayLayout"

    struct Element: Equatable {
        let bundleID: String?
        let frame: CGRect
        let role: String
    }

    private static let messagePrefix = "_updateLayout"
    private static let primaryRole = "primary"
    /// SpringBoard's frames are in points, some fractional.
    private static let tolerance: CGFloat = 1
    private static let number = #"(-?[\d.]+)"#
    private static let rect = #"\{\{\#(number), \#(number)\}, \{\#(number), \#(number)\}\}"#
    private static let boundsPattern = try! NSRegularExpression(pattern: #"\bbounds = \#(rect);"#)
    private static let elementPattern = try! NSRegularExpression(
        pattern: #"<SBSDisplayLayoutElement: [^;]+; [^;]+; (?:bundleID: ([^;]+); )?frame: \#(rect);[^>]*role: (\w+)>"#)

    let bounds: CGRect
    let elements: [Element]

    init(bounds: CGRect, elements: [Element]) {
        self.bounds = bounds
        self.elements = elements
    }

    init?(message: String) {
        guard message.hasPrefix(Self.messagePrefix), let match = Self.boundsPattern.firstMatch(in: message, range: Self.whole(message)),
              let bounds = Self.rect(in: match, at: 1, of: message) else {
            return nil
        }
        self.bounds = bounds
        elements = Self.elementPattern.matches(in: message, range: Self.whole(message)).compactMap { match in
            guard let frame = Self.rect(in: match, at: 2, of: message), let role = Self.group(6, of: match, in: message) else {
                return nil
            }
            return Element(bundleID: Self.group(1, of: match, in: message), frame: frame, role: role)
        }
    }

    /// Nil unless one app is primary, as SpringBoard's own app switcher is when a drag opens it.
    var splitLayout: SplitLayout? {
        let primaries = elements.filter { $0.role == Self.primaryRole }
        guard primaries.count == 1, let app = primaries.first, app.bundleID != nil else { return nil }
        if app.frame.width >= bounds.width - Self.tolerance { return .full }
        if app.frame.minX <= bounds.minX + Self.tolerance { return .left }
        if app.frame.maxX >= bounds.maxX - Self.tolerance { return .right }
        return nil
    }

    private static func whole(_ string: String) -> NSRange { NSRange(string.startIndex..., in: string) }

    private static func group(_ index: Int, of match: NSTextCheckingResult, in string: String) -> String? {
        Range(match.range(at: index), in: string).map { String(string[$0]) }
    }

    private static func rect(in match: NSTextCheckingResult, at first: Int, of string: String) -> CGRect? {
        let values = (first..<first + 4).compactMap { group($0, of: match, in: string).flatMap(Double.init) }
        guard values.count == 4 else { return nil }
        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }
}
