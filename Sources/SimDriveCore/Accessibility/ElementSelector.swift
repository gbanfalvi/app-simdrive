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

    /// Whether a hit test at a target's tap point reached it: the hit is the target, or a part of it, in the same app. A
    /// hit in another app is an alert over it. A hit that is another of the screen's elements, such as a key of the
    /// keyboard, covers it even inside its frame. One outside its frame is a sheet or another view. A target without a
    /// frame says nothing, so it counts as reached.
    static func hitReaches(_ target: AccessibilityElement, in targetPID: Int32?, hit: AccessibilityElement, in hitPID: Int32?,
                           among elements: [PlacedElement] = []) -> Bool {
        guard hitPID == targetPID else { return false }
        guard !target.frame.isEmpty, !isSame(hit, as: target) else { return true }
        guard !elements.contains(where: { isSame(hit, as: $0.element) }) else { return false }
        return target.frame.insetBy(dx: -hitTolerance, dy: -hitTolerance).contains(hit.frame)
    }

    /// Elements read separately compare by what identifies them on screen.
    private static func isSame(_ one: AccessibilityElement, as other: AccessibilityElement) -> Bool {
        one.frame == other.frame && one.label == other.label && one.identifier == other.identifier
    }

    /// In points, so a part whose frame touches the target's edge still counts as inside it.
    private static let hitTolerance: CGFloat = 1

    /// Whether the selector names an element that is on screen, which is what `wait` waits for.
    func isShown(in elements: [PlacedElement]) -> Bool {
        elements.contains { !$0.isOffscreen && matches($0.element) }
    }
}

/// A VoiceOver element of the light tree: where `tap` reaches it, as a fraction of the screen, and whether its scroll
/// view shows it.
struct PlacedElement: Sendable {
    /// Positions compared to a thousandth of the screen, finer than a scroll moves and coarser than rounding noise.
    private static let signatureScale: CGFloat = 1000

    let element: AccessibilityElement
    let fraction: CGPoint
    let isOffscreen: Bool
    /// Under a newer presentation, as an alert or a sheet, so a tap cannot reach it though it is on screen.
    var isBehindPresentation = false

    /// What the screen shows, as each element's type, identifier, label and place. Two equal signatures mean nothing
    /// moved: content at rest, or a scroll that reached the end of its content.
    static func signature(of elements: [PlacedElement]) -> String {
        elements.map { placed in
            let x = Int((placed.fraction.x * signatureScale).rounded()), y = Int((placed.fraction.y * signatureScale).rounded())
            let type = placed.element.type.map { "\($0)" } ?? ""
            return "\(type)|\(placed.element.identifier ?? "")|\(placed.element.label ?? "")|\(x),\(y)|\(placed.isOffscreen)"
        }.joined(separator: "\n")
    }
}
