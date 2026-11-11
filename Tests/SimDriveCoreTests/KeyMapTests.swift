import Carbon.HIToolbox
import Testing
@testable import SimDriveCore

struct KeyMapTests {
    @Test(arguments: [
        ("tab", kVK_Tab), ("TAB", kVK_Tab), ("esc", kVK_Escape), ("backspace", kVK_Delete), ("page-down", kVK_PageDown),
        ("a", kVK_ANSI_A), ("/", kVK_ANSI_Slash),
    ])
    func namedKeys(name: String, keyCode: Int) {
        #expect(KeyMap.stroke(named: name) == KeyStroke(keyCode))
    }

    @Test func shiftedCharactersUseTheirBaseKey() {
        #expect(KeyMap.stroke(for: "A") == KeyStroke(kVK_ANSI_A, needsShift: true))
        #expect(KeyMap.stroke(for: "!") == KeyStroke(kVK_ANSI_1, needsShift: true))
        #expect(KeyMap.stroke(for: "\"") == KeyStroke(kVK_ANSI_Quote, needsShift: true))
        #expect(KeyMap.stroke(for: "?") == KeyStroke(kVK_ANSI_Slash, needsShift: true))
    }

    @Test func charactersOutsideTheUSLayoutHaveNoStroke() {
        #expect(KeyMap.stroke(for: "é") == nil)
        #expect(KeyMap.stroke(for: "✓") == nil)
        #expect(KeyMap.stroke(named: "nope") == nil)
    }

    @Test func modifierAliases() {
        #expect(KeyModifier(name: "cmd") == .command)
        #expect(KeyModifier(name: "Alt") == .option)
        #expect(KeyModifier(name: "ctrl") == .control)
        #expect(KeyModifier(name: "hyper") == nil)
    }
}
