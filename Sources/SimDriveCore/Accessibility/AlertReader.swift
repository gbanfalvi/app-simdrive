import Foundation
import SimDriveNative

/// What `alert accept` and `alert dismiss` tap.
enum AlertAnswer: String, CaseIterable, Sendable {
    case accept, dismiss
}

/// Finds an alert in a tree, and the button that accepts or dismisses it. UIKit draws every alert, an app's own and
/// SpringBoard's system ones alike, in an `_UIAlertController…View` whose VoiceOver elements are its title, its message,
/// then its buttons (iPhone, iOS 27.2).
enum AlertReader {
    /// The alert's own view: on iPhone and Apple TV `_UIAlertControllerPhoneTVMacView`, elsewhere `_UIAlertControllerView`.
    /// Its parts, as `_UIAlertControllerActionView`, share the prefix, so only these count.
    private static let containerClasses: Set<String> = ["_UIAlertControllerPhoneTVMacView", "_UIAlertControllerView"]
    /// The suffixes of the identifiers a permission alert gives its buttons, as `kTCCServicePhotos-allow-button`.
    private static let acceptIdentifierSuffix = "-allow-button"
    private static let dismissIdentifierSuffix = "-deny-button"
    /// Labels that answer each way, most specific first. Others fall back to UIKit's order: the default action last,
    /// the cancel action first.
    private static let acceptLabels = ["Allow", "Allow Full Access", "Allow While Using App", "Allow Once", "Open", "OK", "Continue",
                                       "Confirm", "Yes", "Done"]
    private static let dismissLabels = ["Don’t Allow", "Don't Allow", "Cancel", "Not Now", "Dismiss", "Ask App Not to Track", "No",
                                        "Close", "Later"]

    /// An alert's container and its VoiceOver elements: texts, then buttons.
    struct Alert: Equatable {
        let title: String?
        let message: String?
        let buttons: [AccessibilityElement]
    }

    /// The newest alert in `root`, the last one in hierarchy order, or nil.
    static func alert(in root: AccessibilityElement) -> Alert? {
        guard let container = newestContainer(in: root) else { return nil }
        let elements = voiceOverElements(of: container)
        let texts = elements.filter { $0.traits.contains(.staticText) }.compactMap(\.label)
        let buttons = elements.filter { $0.traits.contains(.button) }
        guard !buttons.isEmpty else { return nil }
        return Alert(title: texts.first ?? container.label, message: texts.dropFirst().first, buttons: buttons)
    }

    /// The button that gives `answer`.
    static func button(for answer: AlertAnswer, in buttons: [AccessibilityElement]) -> AccessibilityElement? {
        let (suffix, labels) = answer == .accept ? (acceptIdentifierSuffix, acceptLabels) : (dismissIdentifierSuffix, dismissLabels)
        if let byIdentifier = buttons.first(where: { $0.identifier?.hasSuffix(suffix) == true }) { return byIdentifier }
        for label in labels {
            if let byLabel = buttons.first(where: { $0.label == label }) { return byLabel }
        }
        guard buttons.count > 1 else { return buttons.first }
        let otherWay = answer == .accept ? dismissLabels : acceptLabels
        let candidates = buttons.filter { !otherWay.contains($0.label ?? "") }
        return answer == .accept ? (candidates.last ?? buttons.last) : (candidates.first ?? buttons.first)
    }

    /// The last container in hierarchy order, which is the newest presentation's.
    private static func newestContainer(in element: AccessibilityElement) -> AccessibilityElement? {
        if let className = element.className, containerClasses.contains(className) { return element }
        for child in element.children.reversed() {
            if let found = newestContainer(in: child) { return found }
        }
        return nil
    }

    private static func voiceOverElements(of element: AccessibilityElement) -> [AccessibilityElement] {
        element.isVoiceOverElement ? [element] : element.children.flatMap(voiceOverElements)
    }
}
