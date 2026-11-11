import AppKit
import Carbon.HIToolbox

enum KeyModifier: String, CaseIterable, Sendable {
    case command, shift, option, control

    private static let aliases: [String: KeyModifier] = ["cmd": .command, "alt": .option, "opt": .option, "ctrl": .control]

    init?(name: String) {
        let lowered = name.lowercased()
        guard let modifier = KeyModifier(rawValue: lowered) ?? Self.aliases[lowered] else { return nil }
        self = modifier
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .command: .command
        case .shift: .shift
        case .option: .option
        case .control: .control
        }
    }
}

/// One key press on a US keyboard layout: a Mac virtual key code, and whether the character needs Shift.
struct KeyStroke: Equatable, Sendable {
    let keyCode: UInt16
    let needsShift: Bool

    init(_ keyCode: Int, needsShift: Bool = false) {
        self.keyCode = UInt16(keyCode)
        self.needsShift = needsShift
    }
}

/// Mac virtual key codes for key names and US-layout characters. The guest reads the main keyboard as US.
enum KeyMap {
    private static let named: [String: KeyStroke] = [
        "tab": KeyStroke(kVK_Tab), "space": KeyStroke(kVK_Space), "return": KeyStroke(kVK_Return),
        "enter": KeyStroke(kVK_Return), "escape": KeyStroke(kVK_Escape), "esc": KeyStroke(kVK_Escape),
        "delete": KeyStroke(kVK_Delete), "backspace": KeyStroke(kVK_Delete), "forward-delete": KeyStroke(kVK_ForwardDelete),
        "left": KeyStroke(kVK_LeftArrow), "right": KeyStroke(kVK_RightArrow),
        "up": KeyStroke(kVK_UpArrow), "down": KeyStroke(kVK_DownArrow),
        "home": KeyStroke(kVK_Home), "end": KeyStroke(kVK_End),
        "page-up": KeyStroke(kVK_PageUp), "page-down": KeyStroke(kVK_PageDown),
        "f1": KeyStroke(kVK_F1), "f2": KeyStroke(kVK_F2), "f3": KeyStroke(kVK_F3), "f4": KeyStroke(kVK_F4),
        "f5": KeyStroke(kVK_F5), "f6": KeyStroke(kVK_F6), "f7": KeyStroke(kVK_F7), "f8": KeyStroke(kVK_F8),
        "f9": KeyStroke(kVK_F9), "f10": KeyStroke(kVK_F10), "f11": KeyStroke(kVK_F11), "f12": KeyStroke(kVK_F12),
    ]

    private static let unshifted: [Character: Int] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E, "f": kVK_ANSI_F,
        "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
        "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R,
        "s": kVK_ANSI_S, "t": kVK_ANSI_T, "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
        "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "`": kVK_ANSI_Grave, "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon, "'": kVK_ANSI_Quote,
        ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        " ": kVK_Space, "\t": kVK_Tab, "\n": kVK_Return,
    ]

    private static let shifted: [Character: Character] = [
        "~": "`", "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
        "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/",
    ]

    /// A named key such as `tab` or `page-down`, or a single US-layout character.
    static func stroke(named name: String) -> KeyStroke? {
        if let stroke = named[name.lowercased()] { return stroke }
        guard name.count == 1, let character = name.first else { return nil }
        return stroke(for: character)
    }

    static func stroke(for character: Character) -> KeyStroke? {
        if let code = unshifted[character] { return KeyStroke(code) }
        if character.isUppercase, let lower = character.lowercased().first, let code = unshifted[lower] {
            return KeyStroke(code, needsShift: true)
        }
        if let base = shifted[character], let code = unshifted[base] { return KeyStroke(code, needsShift: true) }
        return nil
    }

    static var keyNames: [String] { named.keys.sorted() }
}
