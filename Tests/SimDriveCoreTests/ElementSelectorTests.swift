import CoreGraphics
import Testing
@testable import SimDriveCore
@testable import SimDriveNative

struct ElementSelectorTests {
    private static func placed(label: String? = nil, identifier: String? = nil, at x: CGFloat = 0.5,
                               offscreen: Bool = false) -> PlacedElement {
        var element = AccessibilityElement()
        element.label = label
        element.identifier = identifier
        return PlacedElement(element: element, fraction: CGPoint(x: x, y: 0.5), isOffscreen: offscreen)
    }

    @Test func aLabelPicksTheOneOnscreenElementWithExactlyThatLabel() throws {
        let elements = [Self.placed(label: "View all", at: 0.1), Self.placed(label: "View", at: 0.2), Self.placed(label: "view", at: 0.3)]
        #expect(try ElementSelector.label("View").resolve(in: elements)?.fraction.x == 0.2)
    }

    @Test func anIdentifierIgnoresLabels() throws {
        let elements = [Self.placed(label: "play-button", at: 0.1), Self.placed(label: "Play", identifier: "play-button", at: 0.2)]
        #expect(try ElementSelector.identifier("play-button").resolve(in: elements)?.fraction.x == 0.2)
    }

    @Test func anOnscreenMatchWinsOverOffscreenOnes() throws {
        let elements = [Self.placed(label: "Row", at: 0.1, offscreen: true), Self.placed(label: "Row", at: 0.2)]
        #expect(try ElementSelector.label("Row").resolve(in: elements)?.fraction.x == 0.2)
    }

    @Test func noMatchIsNil() throws {
        #expect(try ElementSelector.label("Missing").resolve(in: [Self.placed(label: "View")]) == nil)
    }

    @Test func severalOnscreenMatchesAreAmbiguous() {
        let elements = [Self.placed(label: "Delete", at: 0.1), Self.placed(label: "Delete", at: 0.2)]
        let error = #expect(throws: SimDriveError.self) { try ElementSelector.label("Delete").resolve(in: elements) }
        #expect(error?.code == .ambiguousElement)
    }

    @Test func onlyOffscreenMatchesCannotBeTapped() {
        let error = #expect(throws: SimDriveError.self) {
            try ElementSelector.label("Row").resolve(in: [Self.placed(label: "Row", offscreen: true)])
        }
        #expect(error?.code == .elementOffscreen)
    }

    @Test func theSignatureChangesWhenContentMovesAndNotOtherwise() {
        let screen = [Self.placed(label: "Row 1", at: 0.5), Self.placed(label: "Row 2", at: 0.6)]
        let same = [Self.placed(label: "Row 1", at: 0.5), Self.placed(label: "Row 2", at: 0.6)]
        let scrolled = [Self.placed(label: "Row 1", at: 0.45), Self.placed(label: "Row 2", at: 0.55)]
        #expect(PlacedElement.signature(of: screen) == PlacedElement.signature(of: same))
        #expect(PlacedElement.signature(of: screen) != PlacedElement.signature(of: scrolled))
    }

    private static func element(_ frame: CGRect) -> AccessibilityElement {
        var element = AccessibilityElement()
        element.frame = frame
        return element
    }

    @Test func aHitOnTheTargetOrInsideItReachesIt() {
        let row = Self.element(CGRect(x: 0, y: 100, width: 400, height: 44))
        #expect(ElementSelector.hitReaches(row, in: 1, hit: row, in: 1))
        #expect(ElementSelector.hitReaches(row, in: 1, hit: Self.element(CGRect(x: 10, y: 110, width: 30, height: 20)), in: 1))
    }

    @Test func aHitElsewhereOrInAnotherAppIsCovered() {
        let row = Self.element(CGRect(x: 0, y: 600, width: 400, height: 44))
        let key = Self.element(CGRect(x: 0, y: 580, width: 40, height: 50))
        #expect(!ElementSelector.hitReaches(row, in: 1, hit: key, in: 1))
        #expect(!ElementSelector.hitReaches(row, in: 1, hit: row, in: 2))
    }

    /// A key of the keyboard can fit inside a large button's frame, and is still not part of it.
    @Test func anotherElementInsideTheTargetsFrameCoversIt() {
        let button = Self.element(CGRect(x: 100, y: 500, width: 200, height: 80))
        var key = Self.element(CGRect(x: 180, y: 510, width: 40, height: 50))
        key.label = "g"
        let screen = [PlacedElement(element: button, fraction: .zero, isOffscreen: false),
                      PlacedElement(element: key, fraction: .zero, isOffscreen: false)]
        #expect(!ElementSelector.hitReaches(button, in: 1, hit: key, in: 1, among: screen))
        #expect(ElementSelector.hitReaches(button, in: 1, hit: button, in: 1, among: screen))
    }

    @Test func anOffscreenMatchIsNotShown() {
        #expect(!ElementSelector.label("Row").isShown(in: [Self.placed(label: "Row", offscreen: true)]))
        #expect(ElementSelector.label("Row").isShown(in: [Self.placed(label: "Row")]))
    }
}
