import CoreGraphics
import Foundation
import Testing
@testable import SimDriveNative

struct AccessibilityElementTests {
    private static let privateTraitBit: UInt64 = 1 << 33
    private static let content = [AccessibilityCustomContent(label: "Breed", value: "Corgi", isImportant: true)]

    @Test func readsVoiceOverAttributes() throws {
        let traits = AccessibilityTrait.button.rawValue | AccessibilityTrait.selected.rawValue | Self.privateTraitBit
        let element = try #require(AccessibilityElement(snapshot: Self.node([
            .label: "Play", .value: "", .hint: "Plays the video", .identifier: "play-button", .traits: NSNumber(value: traits),
            .automationType: NSNumber(value: ElementType.button.rawValue), .language: "en-US", .isAccessibilityElement: true,
            .frame: NSValue(rect: CGRect(x: 16, y: 134, width: 370, height: 30)), .activationPoint: NSValue(point: CGPoint(x: 201, y: 149)),
            .expandedStatus: 2, .headingLevel: 0, .containerType: 256, .inputLabels: ["Play", "Start"],
            .customActions: [["CustomActionName": "Delete"], ["CustomActionName": "Share"]],
        ]), customContent: { _ in [] }))
        #expect(element.label == "Play")
        #expect(element.value == nil)
        #expect(element.hint == "Plays the video")
        #expect(element.identifier == "play-button")
        #expect(element.traits == [.button, .selected])
        #expect(element.type == .button)
        #expect(element.language == "en-US")
        #expect(element.isVoiceOverElement)
        #expect(element.frame == CGRect(x: 16, y: 134, width: 370, height: 30))
        #expect(element.activationPoint == CGPoint(x: 201, y: 149))
        #expect(element.isExpanded == false)
        #expect(element.headingLevel == nil)
        #expect(element.containerType == .semanticGroup)
        #expect(element.inputLabels == ["Play", "Start"])
        #expect(element.customActions == ["Delete", "Share"])
    }

    @Test func defaultsWhenAttributesAreMissing() throws {
        let element = try #require(AccessibilityElement(snapshot: Self.node([.label: "Probe", .inputLabels: ["Probe"],
            .automationType: NSNumber(value: ElementType.any.rawValue)]), customContent: { _ in [] }))
        #expect(element.type == nil)
        #expect(element.inputLabels.isEmpty)
        #expect(element.isExpanded == nil)
        #expect(element.activationPoint == nil)
        #expect(!element.isVoiceOverElement)
    }

    @Test func ignoresActivationPointsOutsideTheFrame() throws {
        let element = try #require(AccessibilityElement(snapshot: Self.node([
            .frame: NSValue(rect: CGRect(x: 16, y: 381, width: 370, height: 30)), .activationPoint: NSValue(point: CGPoint(x: 10, y: 10)),
        ]), customContent: { _ in [] }))
        #expect(element.activationPoint == nil)
    }

    @Test func voiceOverSkipsElementsInsideElements() throws {
        let label = Self.node([.label: "Play", .isAccessibilityElement: true])
        let button = Self.node([.label: "Play", .isAccessibilityElement: true], children: [Self.node([:], children: [label])])
        let element = try #require(AccessibilityElement(snapshot: button, customContent: { _ in [] }))
        let nested = try #require(element.children.first?.children.first)
        #expect(element.isVoiceOverElement)
        #expect(!nested.isVoiceOverElement)
    }

    @Test func readsCustomContentOfVoiceOverElementsOnly() throws {
        let object = NSObject()
        let child = Self.node([.label: "Dog", .isAccessibilityElement: true], element: object)
        let container = Self.node([.label: "Pair"], children: [child], element: NSObject())
        var asked: [ObjectIdentifier] = []
        let element = try #require(AccessibilityElement(snapshot: container, customContent: { object in
            asked.append(ObjectIdentifier(object))
            return Self.content
        }))
        #expect(asked == [ObjectIdentifier(object)])
        #expect(element.customContent.isEmpty)
        #expect(element.children.map(\.customContent) == [Self.content])
    }

    @Test func listsAnElementOnceWhereverItRecurs() throws {
        let cell = NSObject()
        let wrapper = Self.node([.label: "Wrapper"], children: [Self.node([.label: "General"], element: cell)])
        let table = Self.node([.label: "Table"], children: [wrapper, Self.node([.label: "General"], element: cell)])
        let element = try #require(AccessibilityElement(snapshot: table, customContent: { _ in [] }))
        #expect(element.children.map(\.label) == ["Wrapper"])
        #expect(element.children.first?.children.map(\.label) == ["General"])
    }

    @Test func rangesOnlyAdjustableElements() throws {
        let slider: [SnapshotAttribute: Any] = [.traits: NSNumber(value: AccessibilityTrait.adjustable.rawValue),
                                                .minimumValue: 0, .maximumValue: 1, .numericValue: 0.25]
        let adjustable = try #require(AccessibilityElement(snapshot: Self.node(slider), customContent: { _ in [] }))
        #expect(adjustable.range == AdjustableRange(minimum: 0, maximum: 1, value: 0.25))
        var button = slider
        button[.traits] = NSNumber(value: AccessibilityTrait.button.rawValue)
        #expect(AccessibilityElement(snapshot: Self.node(button), customContent: { _ in [] })?.range == nil)
        var unbounded = slider
        unbounded[.maximumValue] = Double.nan
        #expect(AccessibilityElement(snapshot: Self.node(unbounded), customContent: { _ in [] })?.range == nil)
    }

    @Test func rejectsNonDictionaries() {
        #expect(AccessibilityElement(snapshot: "AXProbe", customContent: { _ in [] }) == nil)
    }

    @Test func elementTypesMatchXCUITestRawValues() {
        #expect(ElementType.button.rawValue == 9)
        #expect(ElementType.switch.rawValue == 40)
        #expect(ElementType.staticText.rawValue == 48)
        #expect(ElementType.cell.rawValue == 75)
        #expect(ElementType.statusItem.rawValue == 82)
    }

    @Test func traitBitsAreDistinct() {
        #expect(Set(AccessibilityTrait.allCases.map(\.rawValue)).count == AccessibilityTrait.allCases.count)
        #expect(AccessibilityTrait.allCases.allSatisfy { $0.rawValue.nonzeroBitCount == 1 })
    }

    private static func node(_ attributes: [SnapshotAttribute: Any], children: [Any] = [], element: AnyObject? = nil) -> [String: Any] {
        var node: [String: Any] = [
            SnapshotKey.attributes: Dictionary(uniqueKeysWithValues: attributes.map { (NSNumber(value: $0.key.rawValue), $0.value) }),
            SnapshotKey.children: children,
        ]
        node[SnapshotKey.element] = element
        return node
    }
}
