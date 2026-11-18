import Foundation
import Testing
@testable import SimDriveNative

struct KeyboardSettingsTests {
    private static var inputModes: [String: Any] { [
        "UIKeyboardSupportedInputModes": [
            "en_US": ["HWLayouts": ["US"], "SWLayouts": ["QWERTY"]],
            "en_GB": ["HWLayouts": ["British"], "SWLayouts": ["QWERTY"]],
        ],
        "UIKeyboardDefaultLanguageInputModes": ["en_US": ["en_US"], "en_GB": ["en_GB"]],
    ] }

    private let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)

    private func layout(_ global: [String: Any], lastUsed: String? = nil, ignoringKeyboards: Bool = false) throws -> String? {
        let preferences = root.appending(path: "data/Library/Preferences")
        let runtime = root.appending(path: "runtime")
        let bundle = runtime.appending(path: "System/Library/TextInput/TextInput_en.bundle")
        try FileManager.default.createDirectory(at: preferences, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        func write(_ plist: [String: Any], to url: URL) throws {
            try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
        }
        try write(Self.inputModes, to: bundle.appending(path: "InputMode_en.plist"))
        try write(global, to: preferences.appending(path: ".GlobalPreferences.plist"))
        try write(lastUsed.map { ["KeyboardLastUsed": $0] } ?? [:], to: preferences.appending(path: "com.apple.keyboard.preferences.plist"))
        defer { try? FileManager.default.removeItem(at: root) }
        return KeyboardSettings.layoutName(preferences: preferences, runtimeRoot: runtime, ignoringKeyboards: ignoringKeyboards)
    }

    @Test func beforeKeyboardsAreSetUpTheLanguageDefaultApplies() throws {
        #expect(try layout(["AppleLanguages": ["en-GB"], "AppleKeyboards": ["en_US@sw=QWERTY;hw=Automatic"]]) == "British")
        #expect(try layout(["AppleLanguages": ["en-US"]]) == "US")
    }

    @Test func theLastUsedListedKeyboardApplies() throws {
        let global: [String: Any] = ["AppleLanguages": ["en-US"], "AppleKeyboardsExpanded": true,
                                     "AppleKeyboards": ["en_US@sw=QWERTY;hw=Automatic", "en_GB@sw=QWERTY;hw=Automatic"]]
        #expect(try layout(global) == "US")
        #expect(try layout(global, lastUsed: "en_GB@sw=QWERTY;hw=Automatic") == "British")
        #expect(try layout(global, lastUsed: "en_GB@sw=QWERTY;hw=Automatic", ignoringKeyboards: true) == "US")
    }

    @Test func aNamedHardwareLayoutWins() throws {
        #expect(try layout(["AppleKeyboardsExpanded": true, "AppleKeyboards": ["en_US@sw=QWERTY;hw=German"]]) == "German")
    }
}
