import AppKit
import Carbon.HIToolbox

/// A hardware keyboard layout of the guest's runtime, which the guest reads key presses with. Its data is indexed by HID
/// usage, so the same character needs a different key on each layout.
package struct KeyboardLayout: Sendable {
    package typealias Key = (keyCode: UInt16, flags: NSEvent.ModifierFlags)

    /// A character the layout has no keys for, or whose keys would combine with the next ones.
    package struct MissingKey: Error {
        package let character: Character
    }

    private struct Stroke: Equatable {
        let usage: Int
        var shift = false
        var option = false
    }

    private static let usName = "US"
    private static let bundlePath = "System/Library/KeyboardLayouts/USBKeyboardLayouts.bundle"
    private static let indexFile = "USBKeyboardLayouts.plist"
    private static let layoutsDirectory = "uchrs"
    private static let fileKey = "KeyLayoutFileName"
    private static let preferencesPath = "Library/Preferences"
    private static let returnUsage = 0x28
    private static let tabUsage = 0x2B
    /// Mac virtual key codes by HID usage for the keys that type characters. The runtime's layouts put the ISO key beside
    /// Return at 0x31, so 0x32 is left out.
    private static let keyCodes: [Int: Int] = [
        0x04: kVK_ANSI_A, 0x05: kVK_ANSI_B, 0x06: kVK_ANSI_C, 0x07: kVK_ANSI_D, 0x08: kVK_ANSI_E, 0x09: kVK_ANSI_F,
        0x0A: kVK_ANSI_G, 0x0B: kVK_ANSI_H, 0x0C: kVK_ANSI_I, 0x0D: kVK_ANSI_J, 0x0E: kVK_ANSI_K, 0x0F: kVK_ANSI_L,
        0x10: kVK_ANSI_M, 0x11: kVK_ANSI_N, 0x12: kVK_ANSI_O, 0x13: kVK_ANSI_P, 0x14: kVK_ANSI_Q, 0x15: kVK_ANSI_R,
        0x16: kVK_ANSI_S, 0x17: kVK_ANSI_T, 0x18: kVK_ANSI_U, 0x19: kVK_ANSI_V, 0x1A: kVK_ANSI_W, 0x1B: kVK_ANSI_X,
        0x1C: kVK_ANSI_Y, 0x1D: kVK_ANSI_Z, 0x1E: kVK_ANSI_1, 0x1F: kVK_ANSI_2, 0x20: kVK_ANSI_3, 0x21: kVK_ANSI_4,
        0x22: kVK_ANSI_5, 0x23: kVK_ANSI_6, 0x24: kVK_ANSI_7, 0x25: kVK_ANSI_8, 0x26: kVK_ANSI_9, 0x27: kVK_ANSI_0,
        0x2C: kVK_Space, 0x2D: kVK_ANSI_Minus, 0x2E: kVK_ANSI_Equal, 0x2F: kVK_ANSI_LeftBracket,
        0x30: kVK_ANSI_RightBracket, 0x31: kVK_ANSI_Backslash, 0x33: kVK_ANSI_Semicolon, 0x34: kVK_ANSI_Quote,
        0x35: kVK_ANSI_Grave, 0x36: kVK_ANSI_Comma, 0x37: kVK_ANSI_Period, 0x38: kVK_ANSI_Slash, 0x64: kVK_ISO_Section,
        returnUsage: kVK_Return, tabUsage: kVK_Tab,
    ]
    private static let printingUsages = keyCodes.keys.filter { $0 != returnUsage && $0 != tabUsage }.sorted()

    package let name: String
    private let uchr: Data
    private let strokes: [Character: [Stroke]]

    /// The layout a newly launched app types with, or nil for US or when the settings name no layout the runtime ships.
    /// An app keeps the layout it was launched with.
    @MainActor
    package static func active(on device: SimulatorDevice) -> KeyboardLayout? {
        guard let root = device.runtimeRoot, let data = device.dataDirectory else { return nil }
        let preferences = data.appending(path: preferencesPath)
        let set = KeyboardSettings.layoutName(preferences: preferences, runtimeRoot: root, ignoringKeyboards: false)
        // iOS types on its language's default keyboard when it cannot use the one that is set.
        guard let found = set.flatMap({ file(named: $0, runtimeRoot: root) })
                ?? KeyboardSettings.layoutName(preferences: preferences, runtimeRoot: root, ignoringKeyboards: true)
                    .flatMap({ file(named: $0, runtimeRoot: root) }),
              found.name != usName, let uchr = try? Data(contentsOf: found.file) else {
            return nil
        }
        return KeyboardLayout(name: found.name, uchr: uchr)
    }

    /// Inverts the layout data into the keys that type each character, including those composed with one dead key.
    private init?(name: String, uchr: Data) {
        guard UCHRValidation.isWellFormed(uchr) else { return nil }
        let keys = [(false, false), (true, false), (false, true), (true, true)].flatMap { shift, option in
            Self.printingUsages.map { Stroke(usage: $0, shift: shift, option: option) }
        }
        let alone = keys.map { Self.translate($0, uchr: uchr, deadKeyState: 0) }
        // A state left behind that changes what the next key types makes the key unusable: its character would depend
        // on the key after it.
        var disturbing: [UInt32: Bool] = [0: false]
        func disturbs(_ state: UInt32) -> Bool {
            if let known = disturbing[state] { return known }
            let result = zip(keys, alone).contains { Self.translate($0, uchr: uchr, deadKeyState: state).text != $1.text }
            disturbing[state] = result
            return result
        }
        var strokes: [Character: [Stroke]] = [:]
        var deadKeys: [(stroke: Stroke, state: UInt32)] = []
        // `keys` runs from no modifiers to Shift and Option, so a character keeps the simplest key that types it.
        for (stroke, (text, state)) in zip(keys, alone) {
            if text.count == 1, let character = text.first {
                if strokes[character] == nil, !disturbs(state) { strokes[character] = [stroke] }
            } else if text.isEmpty, state != 0 {
                deadKeys.append((stroke, state))
            }
        }
        for dead in deadKeys {
            for second in keys where !second.option {
                let (text, state) = Self.translate(second, uchr: uchr, deadKeyState: dead.state)
                guard text.count == 1, let character = text.first, strokes[character] == nil, !disturbs(state) else { continue }
                strokes[character] = [dead.stroke, second]
            }
        }
        strokes["\n"] = [Stroke(usage: Self.returnUsage)]
        strokes["\t"] = [Stroke(usage: Self.tabUsage)]
        self.name = name
        self.uchr = uchr
        self.strokes = strokes
    }

    /// Characters without keys of their own are typed scalar by scalar, and the plan is replayed through the layout.
    package func keys(for text: String) throws(MissingKey) -> [Key] {
        var plan: [Stroke] = []
        for character in text {
            if let known = strokes[character] {
                plan += known
                continue
            }
            let parts = character.unicodeScalars.map { strokes[Character($0)] }
            guard parts.count > 1, !parts.contains(where: { $0 == nil }) else { throw MissingKey(character: character) }
            plan += parts.flatMap { $0 ?? [] }
        }
        let typed = typed(by: plan)
        guard typed == text else {
            throw MissingKey(character: zip(typed, text).first { $0 != $1 }?.1 ?? text.last ?? " ")
        }
        return plan.compactMap { stroke in
            guard let keyCode = Self.keyCodes[stroke.usage] else { return nil }
            var flags: NSEvent.ModifierFlags = []
            if stroke.shift { flags.insert(.shift) }
            if stroke.option { flags.insert(.option) }
            return (UInt16(keyCode), flags)
        }
    }

    private func typed(by plan: [Stroke]) -> String {
        var state: UInt32 = 0
        var result = ""
        for stroke in plan {
            let (text, next) = Self.translate(stroke, uchr: uchr, deadKeyState: state)
            result += stroke.usage == Self.returnUsage ? "\n" : text
            state = next
        }
        return result
    }

    private static func translate(_ stroke: Stroke, uchr: Data, deadKeyState: UInt32) -> (text: String, state: UInt32) {
        let modifiers = UInt32((stroke.shift ? shiftKey : 0) | (stroke.option ? optionKey : 0)) >> 8
        var state = deadKeyState
        var length = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = uchr.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return OSStatus(paramErr) }
            return UCKeyTranslate(layout, UInt16(stroke.usage), UInt16(kUCKeyActionDown), modifiers, 0, 0,
                                  &state, characters.count, &length, &characters)
        }
        guard status == noErr else { return ("", 0) }
        return (String(utf16CodeUnits: characters, count: min(length, characters.count)), state)
    }

    /// The runtime's spelling of a layout name, and the file that holds it.
    private static func file(named name: String, runtimeRoot: URL) -> (name: String, file: URL)? {
        let bundle = runtimeRoot.appending(path: bundlePath)
        let index = propertyList(at: bundle.appending(path: indexFile)) as? [String: [String: Any]] ?? [:]
        let known = index[name] != nil ? name : index.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame }
        guard let known, let file = index[known]?[fileKey] as? String, !file.contains("/") else { return nil }
        return (known, bundle.appending(path: layoutsDirectory).appending(path: file))
    }

    fileprivate static func propertyList(at url: URL) -> Any? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil)
    }
}

/// Which hardware layout a newly launched app types with, from the guest's keyboard settings. AXe measured the rules on
/// iOS 27.2 by typing fixed keys under each setting.
enum KeyboardSettings {
    private static let automatic = "Automatic"
    private static let groupPrefix = "Group-"
    private static let fallbackBundle = "mul"

    /// A keyboard identifier such as `fr_FR@sw=AZERTY-French;hw=French;ml=1`, taken apart.
    private struct Mode: Equatable {
        let name: String
        var software: String?
        var hardware: String?
        var group: String?

        var language: String { String(name.prefix { $0 != "_" && $0 != "-" }) }

        init(_ identifier: String) {
            let parts = identifier.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            name = String(parts[0])
            for option in parts.dropFirst().joined().split(separator: ";") {
                let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                switch pair[0] {
                case "sw": software = pair[1]
                case "hw": hardware = pair[1]
                case "ml": group = pair[1]
                default: break
                }
            }
        }
    }

    private struct InputModes {
        var hardwareLayouts: [String: [String]] = [:]
        var softwareLayouts: [String: [String]] = [:]
        var defaults: [String: [String]] = [:]
    }

    /// With the keyboards set up, the active one is the one last used if listed exactly, else the first; before that, the
    /// language's default keyboards. A multilingual group types with its first keyboard. `hw=Automatic`, or none, means
    /// the first hardware layout the runtime lists for the keyboard.
    static func layoutName(preferences: URL, runtimeRoot: URL, ignoringKeyboards: Bool) -> String? {
        let global = KeyboardLayout.propertyList(at: preferences.appending(path: ".GlobalPreferences.plist")) as? [String: Any] ?? [:]
        let keyboard = KeyboardLayout.propertyList(at: preferences.appending(path: "com.apple.keyboard.preferences.plist"))
            as? [String: Any] ?? [:]
        var cache: [String: InputModes?] = [:]
        func inputModes(_ language: String) -> InputModes? {
            if let known = cache[language] { return known }
            let modes = Self.inputModes(language: language, runtimeRoot: runtimeRoot)
            cache[language] = modes
            return modes
        }
        let expanded = global["AppleKeyboardsExpanded"] as? Bool ?? false
        var candidates = expanded && !ignoringKeyboards ? global["AppleKeyboards"] as? [String] ?? [] : []
        let listed = !candidates.isEmpty
        if !listed {
            search: for language in global["AppleLanguages"] as? [String] ?? [] {
                let parts = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
                guard let base = parts.first, let defaults = inputModes(base)?.defaults else { continue }
                for count in (1...parts.count).reversed() {
                    if let modes = defaults[parts.prefix(count).joined(separator: "_")] {
                        candidates = modes
                        break search
                    }
                }
            }
        }
        let modes = candidates.map(Mode.init)
        func full(_ mode: Mode) -> Mode {
            var mode = mode
            mode.software = mode.software ?? inputModes(mode.language)?.softwareLayouts[mode.name]?.first
            mode.hardware = mode.hardware ?? automatic
            return mode
        }
        let last = ignoringKeyboards ? nil : (keyboard["KeyboardLastUsed"] as? String).map { full(Mode($0)) }
        var active = modes.firstIndex { full($0) == last } ?? 0
        guard modes.indices.contains(active) else { return nil }
        if listed, let group = modes[active].group {
            active = modes.firstIndex { $0.group == group } ?? active
        }
        let mode = modes[active]
        if let hardware = mode.hardware, hardware != automatic { return hardware }
        guard let layout = inputModes(mode.language)?.hardwareLayouts[mode.name]?.first, !layout.hasPrefix(groupPrefix) else {
            return nil
        }
        return layout
    }

    /// A language with few keyboards has no bundle of its own and is described in the `mul` one.
    private static func inputModes(language: String, runtimeRoot: URL) -> InputModes? {
        guard !language.isEmpty, language.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        for bundle in [language, fallbackBundle] {
            let url = runtimeRoot.appending(path: "System/Library/TextInput/TextInput_\(bundle).bundle/InputMode_\(language).plist")
            guard let plist = KeyboardLayout.propertyList(at: url) as? [String: Any] else { continue }
            var modes = InputModes()
            for (name, mode) in plist["UIKeyboardSupportedInputModes"] as? [String: [String: Any]] ?? [:] {
                modes.hardwareLayouts[name] = mode["HWLayouts"] as? [String]
                modes.softwareLayouts[name] = mode["SWLayouts"] as? [String]
            }
            modes.defaults = plist["UIKeyboardDefaultLanguageInputModes"] as? [String: [String]] ?? [:]
            return modes
        }
        return nil
    }
}

/// UCKeyTranslate takes no length and follows the offsets it finds, so the data's tables must lie inside it.
private enum UCHRValidation {
    private static let maximumKeyboardTypes = 64
    private static let maximumTables = 4096
    private static let typeHeaderOffset = 12
    private static let typeHeaderSize = 28

    static func isWellFormed(_ uchr: Data) -> Bool {
        let bytes = [UInt8](uchr)
        func u16(_ offset: Int) -> Int? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int? {
            guard let low = u16(offset), let high = u16(offset + 2) else { return nil }
            return low | high << 16
        }
        func holds(_ offset: Int, _ count: Int) -> Bool { offset >= 0 && count >= 0 && offset + count <= bytes.count }
        guard u16(0) == Int(kUCKeyLayoutHeaderFormat), let featureInfo = u32(4), let typeCount = u32(8),
              (1...maximumKeyboardTypes).contains(typeCount), featureInfo == 0 || holds(featureInfo, 8) else { return false }
        for type in 0..<typeCount {
            let header = typeHeaderOffset + type * typeHeaderSize
            guard let modifiers = u32(header + 8), let tables = u32(header + 12), let records = u32(header + 16),
                  let terminators = u32(header + 20), let sequences = u32(header + 24),
                  u16(modifiers) == Int(kUCKeyModifiersToTableNumFormat), let modifierCount = u32(modifiers + 4),
                  holds(modifiers + 8, modifierCount),
                  u16(tables) == Int(kUCKeyToCharTableIndexFormat), let tableSize = u16(tables + 2),
                  let tableCount = u32(tables + 4), tableCount <= maximumTables, holds(tables + 8, tableCount * 4) else {
                return false
            }
            for table in 0..<tableCount {
                guard let offset = u32(tables + 8 + table * 4), holds(offset, tableSize * 2) else { return false }
            }
            if records != 0 {
                guard u16(records) == Int(kUCKeyStateRecordsIndexFormat), let recordCount = u16(records + 2),
                      holds(records + 4, recordCount * 4) else { return false }
                for record in 0..<recordCount {
                    guard let offset = u32(records + 4 + record * 4), let entryCount = u16(offset + 4), let format = u16(offset + 6),
                          holds(offset + 8, entryCount * (format == Int(kUCKeyStateEntryTerminalFormat) ? 4 : 8)) else { return false }
                }
            }
            if terminators != 0 {
                guard u16(terminators) == Int(kUCKeyStateTerminatorsFormat), let count = u16(terminators + 2),
                      holds(terminators + 4, count * 2) else { return false }
            }
            if sequences != 0 {
                guard u16(sequences) == Int(kUCKeySequenceDataIndexFormat), let count = u16(sequences + 2) else { return false }
                var previous = 4 + (count + 1) * 2
                for index in 0...count {
                    guard let offset = u16(sequences + 4 + index * 2), offset >= previous, holds(sequences, offset) else { return false }
                    previous = offset
                }
            }
        }
        return true
    }
}
