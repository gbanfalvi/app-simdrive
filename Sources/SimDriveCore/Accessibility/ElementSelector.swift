import CoreGraphics
import SimDriveNative

/// Names an element of the light tree by its exact label or accessibility identifier, so steps survive layout changes.
enum ElementSelector: Equatable, Sendable {
    case label(String)
    case identifier(String)

    func matches(_ element: AccessibilityElement) -> Bool {
        switch self {
        case .label(let label): element.label == label
        case .identifier(let identifier): element.identifier == identifier
        }
    }

    /// As the command line spells it, for messages.
    var argument: String {
        switch self {
        case .label(let label): "--label \"\(label)\""
        case .identifier(let identifier): "--id \"\(identifier)\""
        }
    }

    /// The one onscreen element the selector names, or nil when it names none. Several onscreen matches are ambiguous,
    /// and matches that are all offscreen cannot be tapped until scrolled to, so both throw.
    func resolve(in elements: [PlacedElement]) throws -> PlacedElement? {
        let matches = elements.filter { matches($0.element) }
        let onscreen = matches.filter { !$0.isOffscreen }
        switch (onscreen.count, matches.count) {
        case (1, _):
            return onscreen[0]
        case (0, 0):
            return nil
        case (0, _):
            throw SimDriveError(.elementOffscreen, "\(argument) is offscreen; swipe to bring it into view, then retry.")
        default:
            let points = onscreen.map { "(\($0.fraction.x), \($0.fraction.y))" }.joined(separator: ", ")
            throw SimDriveError(.ambiguousElement, "\(argument) names \(onscreen.count) elements, at \(points); use a more "
                                + "specific selector, or tap one of those points.")
        }
    }

    /// Whether the selector names an element that is on screen, which is what `wait` waits for.
    func isShown(in elements: [PlacedElement]) -> Bool {
        elements.contains { !$0.isOffscreen && matches($0.element) }
    }
}

/// A VoiceOver element of the light tree: where `tap` reaches it, as a fraction of the screen, and whether its scroll
/// view shows it.
struct PlacedElement: Sendable {
    let element: AccessibilityElement
    let fraction: CGPoint
    let isOffscreen: Bool
}
