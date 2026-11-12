import CoreGraphics
import Foundation

/// A node of an app's accessibility hierarchy as XCUITest snapshots it: VoiceOver's elements and the views around them.
package struct AccessibilityElement: Equatable, Sendable {
    package var type: ElementType?
    package var label: String?
    package var value: String?
    package var hint: String?
    package var identifier: String?
    package var placeholder: String?
    package var traits: Set<AccessibilityTrait> = []
    /// Whether VoiceOver stops on it: an accessibility element outside other elements, whose descendants VoiceOver skips.
    package var isVoiceOverElement = false
    /// Whether it has the focus engine's focus, as on tvOS.
    package var isFocused = false
    package var isExpanded: Bool?
    package var headingLevel: Int?
    package var containerType: AccessibilityContainerType?
    package var language: String?
    /// Voice Control's names for it, when they differ from its label.
    package var inputLabels: [String] = []
    package var customActions: [String] = []
    package var customContent: [AccessibilityCustomContent] = []
    /// In points of the interface, which turns with the app.
    package var frame: CGRect = .zero
    package var activationPoint: CGPoint?
    package var url: String?
    package var range: AdjustableRange?
    package var className: String?
    package var viewController: String?
    package var children: [AccessibilityElement] = []

    package init() {}

    /// A snapshot node and its descendants. `customContent` reads a VoiceOver element's content from its snapshot object.
    init?(snapshot: Any, customContent: (AnyObject) -> [AccessibilityCustomContent]) {
        var seen = Set<ObjectIdentifier>()
        self.init(snapshot: snapshot, insideElement: false, seen: &seen, customContent: customContent)
    }

    private init?(snapshot: Any, insideElement: Bool, seen: inout Set<ObjectIdentifier>,
                  customContent: (AnyObject) -> [AccessibilityCustomContent]) {
        guard let node = snapshot as? [String: Any] else { return nil }
        // A tvOS table lists its cells under its wrapper view and again as its own children.
        if let object = node[SnapshotKey.element], !seen.insert(ObjectIdentifier(object as AnyObject)).inserted {
            return nil
        }
        let attributes = SnapshotAttributes(node[SnapshotKey.attributes])
        type = attributes.number(.automationType).flatMap { ElementType(rawValue: $0.intValue) }.flatMap { $0 == .any ? nil : $0 }
        label = attributes.string(.label)
        value = attributes.string(.value)
        hint = attributes.string(.hint)
        identifier = attributes.string(.identifier)
        placeholder = attributes.string(.placeholder)
        traits = AccessibilityTrait.traits(in: attributes.number(.traits)?.uint64Value ?? 0)
        isVoiceOverElement = !insideElement && attributes.bool(.isAccessibilityElement)
        isFocused = attributes.bool(.hasFocus)
        isExpanded = ExpandedStatus(rawValue: attributes.number(.expandedStatus)?.intValue ?? 0).flatMap(\.isExpanded)
        headingLevel = attributes.number(.headingLevel).map(\.intValue).flatMap { $0 > 0 ? $0 : nil }
        containerType = attributes.number(.containerType).flatMap { AccessibilityContainerType(rawValue: $0.intValue) }
        language = attributes.string(.language)
        let inputLabels = attributes.strings(.inputLabels)
        self.inputLabels = inputLabels == (label.map { [$0] } ?? []) ? [] : inputLabels
        customActions = attributes.dictionaries(.customActions).compactMap { $0[SnapshotKey.customActionName] as? String }
        frame = attributes.rect(.frame) ?? .zero
        // A plain view marked as an element reports (10, 10) wherever it is.
        activationPoint = attributes.point(.activationPoint).flatMap { frame.contains($0) ? $0 : nil }
        url = attributes.string(.url)
        if traits.contains(.adjustable), let minimum = attributes.number(.minimumValue)?.doubleValue,
           let maximum = attributes.number(.maximumValue)?.doubleValue, minimum.isFinite, maximum.isFinite, maximum > minimum {
            range = AdjustableRange(minimum: minimum, maximum: maximum, value: attributes.number(.numericValue)?.doubleValue)
        }
        className = attributes.string(.className)
        viewController = attributes.string(.viewControllerClass)
        if isVoiceOverElement, let object = node[SnapshotKey.element] {
            self.customContent = customContent(object as AnyObject)
        }
        let childrenAreInsideElement = insideElement || attributes.bool(.isAccessibilityElement)
        children = (node[SnapshotKey.children] as? [Any] ?? []).compactMap {
            AccessibilityElement(snapshot: $0, insideElement: childrenAreInsideElement, seen: &seen, customContent: customContent)
        }
    }
}

/// UIKit's public `UIAccessibilityTraits` bits.
package enum AccessibilityTrait: UInt64, CaseIterable, Sendable {
    case button = 0x1
    case link = 0x2
    case image = 0x4
    case selected = 0x8
    case playsSound = 0x10
    case keyboardKey = 0x20
    case staticText = 0x40
    case summaryElement = 0x80
    case notEnabled = 0x100
    case updatesFrequently = 0x200
    case searchField = 0x400
    case startsMediaSession = 0x800
    case adjustable = 0x1000
    case allowsDirectInteraction = 0x2000
    case causesPageTurn = 0x4000
    case tabBar = 0x8000
    case header = 0x1_0000
    case supportsZoom = 0x4000_0000_0000
    case toggleButton = 0x20_0000_0000_0000

    /// The public traits of a mask; private bits are dropped.
    static func traits(in mask: UInt64) -> Set<AccessibilityTrait> {
        Set(allCases.filter { mask & $0.rawValue != 0 })
    }
}

/// `UIAccessibilityContainerType`, in the accessibility server's encoding.
package enum AccessibilityContainerType: Int, Sendable {
    case landmark = 1
    case dataTable = 2
    case list = 4
    case semanticGroup = 256
}

package struct AccessibilityCustomContent: Equatable, Sendable {
    package let label: String
    package let value: String
    package let isImportant: Bool

    package init(label: String, value: String, isImportant: Bool) {
        self.label = label
        self.value = value
        self.isImportant = isImportant
    }
}

/// An adjustable element's bounds, such as a slider's, and its value within them.
package struct AdjustableRange: Equatable, Sendable {
    package let minimum: Double
    package let maximum: Double
    package let value: Double?
}

/// XCUITest's snapshot attribute numbers. Others can crash the app or return whole subtrees, and visibility (2025)
/// hit-tests every node, which times out on large screens, so only these are requested.
enum SnapshotAttribute: Int, CaseIterable {
    case label = 2001
    case hint = 2002
    case frame = 2003
    case traits = 2004
    case value = 2006
    case activationPoint = 2007
    case language = 2008
    case isAccessibilityElement = 2016
    case url = 2020
    case customActions = 2036
    case hasFocus = 2094
    case expandedStatus = 2114
    case headingLevel = 2180
    case inputLabels = 2186
    case containerType = 2187
    case className = 5003
    case minimumValue = 5005
    case maximumValue = 5006
    case numericValue = 5011
    case identifier = 5019
    case viewControllerClass = 5042
    case placeholder = 5043
    case automationType = 5058
}

enum SnapshotKey {
    static let attributes = "UIAccessibilitySnapshotKeyAttributes"
    static let children = "UIAccessibilitySnapshotKeyChildren"
    static let element = "UIAccessibilitySnapshotKeyElement"
    static let customActionName = "CustomActionName"
}

/// `UIAccessibilityExpandedStatus`.
private enum ExpandedStatus: Int {
    case unsupported = 0
    case expanded = 1
    case collapsed = 2

    var isExpanded: Bool? {
        switch self {
        case .unsupported: nil
        case .expanded: true
        case .collapsed: false
        }
    }
}

/// One snapshot node's attribute values, keyed by attribute number.
private struct SnapshotAttributes {
    private let values: [NSNumber: Any]

    init(_ values: Any?) {
        self.values = values as? [NSNumber: Any] ?? [:]
    }

    /// Strings are omitted when empty; numbers count as their text.
    func string(_ attribute: SnapshotAttribute) -> String? {
        let text = switch self[attribute] {
        case let string as String: string
        case let url as URL: url.absoluteString
        case let number as NSNumber: number.stringValue
        default: String?.none
        }
        return text?.isEmpty == false ? text : nil
    }

    func number(_ attribute: SnapshotAttribute) -> NSNumber? { self[attribute] as? NSNumber }

    func bool(_ attribute: SnapshotAttribute) -> Bool { number(attribute)?.boolValue ?? false }

    func rect(_ attribute: SnapshotAttribute) -> CGRect? { (self[attribute] as? NSValue)?.rectValue }

    func point(_ attribute: SnapshotAttribute) -> CGPoint? { (self[attribute] as? NSValue)?.pointValue }

    func strings(_ attribute: SnapshotAttribute) -> [String] { self[attribute] as? [String] ?? [] }

    func dictionaries(_ attribute: SnapshotAttribute) -> [[String: Any]] { self[attribute] as? [[String: Any]] ?? [] }

    private subscript(attribute: SnapshotAttribute) -> Any? { values[NSNumber(value: attribute.rawValue)] }
}
