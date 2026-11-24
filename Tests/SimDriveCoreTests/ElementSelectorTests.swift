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

    @Test func anOffscreenMatchIsNotShown() {
        #expect(!ElementSelector.label("Row").isShown(in: [Self.placed(label: "Row", offscreen: true)]))
        #expect(ElementSelector.label("Row").isShown(in: [Self.placed(label: "Row")]))
    }
}
