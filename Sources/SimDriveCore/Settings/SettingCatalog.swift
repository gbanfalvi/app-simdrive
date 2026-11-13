/// A device setting that `setting` reads and changes.
struct Setting: Equatable, Sendable {
    /// The values a setting takes.
    enum Kind: Equatable, Sendable {
        case toggle
        case choice([String])
        case number(ClosedRange<Double>)
    }

    /// Where a setting is kept.
    enum Storage: Equatable, Sendable {
        /// A `simctl ui` option.
        case interface(option: String)
        /// A guest preference, and the Darwin notifications that tell running apps it changed. `defaultValue` applies
        /// while the key is unset.
        case preference(domain: String, key: String, defaultValue: JSONValue, notifications: [String])
    }

    private static let toggleNames: [String: Bool] = ["on": true, "off": false, "true": true, "false": false]
    /// Preferences keep numbers as 32-bit floats; four decimals drop their rounding error.
    private static let numberPrecision = 10_000.0

    private enum InterfaceToggle {
        static let on = "enabled"
        static let off = "disabled"
    }

    let name: String
    let kind: Kind
    let storage: Storage
    let minimumOSVersion: Int?
    /// The guest's on-demand launchd daemon that Settings starts when the setting turns on; the setting needs it.
    let service: String?

    init(name: String, kind: Kind, storage: Storage, minimumOSVersion: Int? = nil, service: String? = nil) {
        self.name = name
        self.kind = kind
        self.storage = storage
        self.minimumOSVersion = minimumOSVersion
        self.service = service
    }

    /// True when the OS version is unknown.
    func isAvailable(onOSVersion version: Int?) -> Bool {
        guard let minimumOSVersion, let version else { return true }
        return version >= minimumOSVersion
    }

    /// A command-line value as the setting's JSON value, or nil when the setting does not take it.
    func value(fromArgument text: String) -> JSONValue? {
        switch kind {
        case .toggle:
            return Self.toggleNames[text.lowercased()].map(JSONValue.bool)
        case .choice(let choices):
            return choices.contains(text) ? .string(text) : nil
        case .number(let range):
            guard let number = Double(text), range.contains(number) else { return nil }
            return .number(number)
        }
    }

    var valueDescription: String {
        switch kind {
        case .toggle: "on or off"
        case .choice(let choices): choices.joined(separator: ", ")
        case .number(let range):
            "a number from \(JSONValue.number(range.lowerBound).argument ?? "") to \(JSONValue.number(range.upperBound).argument ?? "")"
        }
    }

    /// The value of a `simctl ui` reading. Readings such as "unsupported" stay as they are.
    func value(fromInterfaceReading reading: String) -> JSONValue {
        guard kind == .toggle else { return .string(reading) }
        switch reading {
        case InterfaceToggle.on: return true
        case InterfaceToggle.off: return false
        default: return .string(reading)
        }
    }

    func interfaceArgument(for value: JSONValue) -> String {
        if case .bool(let isOn) = value { return isOn ? InterfaceToggle.on : InterfaceToggle.off }
        return value.argument ?? ""
    }

    /// The value of a stored preference, which is a number for toggles; nil when the key is unset.
    func value(fromPreference stored: JSONValue?) -> JSONValue {
        guard case .preference(_, _, let defaultValue, _) = storage else { return .null }
        switch (kind, stored) {
        case (.toggle, .number(let number)?): return .bool(number != 0)
        case (.number, .number(let number)?): return .number((number * Self.numberPrecision).rounded() / Self.numberPrecision)
        case (.toggle, .bool?), (.choice, .string?): return stored ?? defaultValue
        default: return defaultValue
        }
    }

    func preferenceValue(for value: JSONValue) -> PreferenceValue {
        switch value {
        case .bool(let isOn): .integer(isOn ? 1 : 0)
        case .number(let number): .float(number)
        default: .string(value.argument ?? "")
        }
    }
}

/// Every setting. Adding a setting means adding a row here.
enum SettingCatalog {
    private static let accessibility = "com.apple.Accessibility"
    private static let uiKit = "com.apple.UIKit"
    private static let notificationPrefix = "com.apple.accessibility."
    private static let cacheNotificationPrefix = "com.apple.accessibility.cache."
    private static let defaultGlassTint = 0.5
    private static let nonBlinkingCursorOSVersion = 18
    private static let glassOSVersion = 26
    private static let fullKeyboardAccessService = "com.apple.fullkeyboardaccess"
    private static let textSizes = [
        "extra-small", "small", "medium", "large", "extra-large", "extra-extra-large", "extra-extra-extra-large",
        "accessibility-medium", "accessibility-large", "accessibility-extra-large", "accessibility-extra-extra-large",
        "accessibility-extra-extra-extra-large",
    ]

    static let appearance = Setting(name: "appearance", kind: .choice(["light", "dark"]), storage: .interface(option: "appearance"))

    /// Not a setting of its own: Settings turns it on before starting a setting's service, so running apps answer that service.
    static let applicationAccessibility = accessibilityToggle("application-accessibility", key: "ApplicationAccessibilityEnabled",
                                                              notification: "application.status", cache: "app.ax")

    static let all: [Setting] = [
        appearance,
        Setting(name: "text-size", kind: .choice(textSizes), storage: .interface(option: "content_size")),
        Setting(name: "increase-contrast", kind: .toggle, storage: .interface(option: "increase_contrast")),
        accessibilityToggle("bold-text", key: "EnhancedTextLegibilityEnabled", notification: "text.legibility.status",
                            cache: "enhance.text.legibility"),
        accessibilityToggle("reduce-motion", key: "ReduceMotionEnabled", notification: "reduce.motion.status", cache: "reduce.motion"),
        accessibilityToggle("prefer-cross-fade", key: "ReduceMotionReduceSlideTransitionsPreference",
                            notification: "reduce.motion.reduce.slide.transitions.status", cache: "reduce.motion.reduce.slide.transitions"),
        accessibilityToggle("reduce-transparency", key: "EnhancedBackgroundContrastEnabled",
                            notification: "enhance.background.contrast.status", cache: "enhance.background.contrast"),
        accessibilityToggle("show-borders", key: "ButtonShapesEnabled", notification: "button.shapes", cache: "button.shapes.enabled"),
        accessibilityToggle("on-off-labels", key: "IncreaseButtonLegibilityEnabled", notification: "increase.button.legibility",
                            cache: "increase.button.legibility"),
        accessibilityToggle("differentiate-without-color", key: "DifferentiateWithoutColor",
                            notification: "differentiate.without.color.status", cache: "differentiate.without.color"),
        accessibilityToggle("prefer-horizontal-text", key: "PrefersHorizontalText", notification: "prefers.horizontal.text",
                            cache: "prefers.horizontal.text"),
        accessibilityToggle("smart-invert", key: "InvertColorsEnabled", notification: "wob.status"),
        accessibilityToggle("grayscale", key: "GrayscaleDisplay", notification: "screencontrast.status"),
        accessibilityToggle("autoplay-video-previews", key: "ReduceMotionAutoplayVideoPreviewsEnabled",
                            notification: "reduce.motion.autoplay.video.previews.status", cache: "reduce.motion.autoplay.video.previews",
                            defaultValue: true),
        accessibilityToggle("autoplay-animated-images", key: "ReduceMotionAutoplayAnimatedImagesEnabled",
                            notification: "reduce.motion.autoplay.animated.images.status", cache: "reduce.motion.autoplay.animated.images",
                            defaultValue: true),
        accessibilityToggle("non-blinking-cursor", key: "PrefersNonBlinkingCursorIndicator", notification: "non.blinking.cursor.status",
                            cache: "non.blinking.cursor.status", minimumOSVersion: nonBlinkingCursorOSVersion),
        accessibilityToggle("full-keyboard-access", key: "FullKeyboardAccessEnabled", notification: "fullkeyboardaccess.status",
                            cache: "full.keyboard.access", service: fullKeyboardAccessService),
        Setting(name: "glass-tint", kind: .number(0...1), storage: .preference(domain: uiKit, key: "UIViewGlassTintAmount",
            defaultValue: .number(defaultGlassTint), notifications: ["UIViewGlassTintAmountUpdateNotification"]),
            minimumOSVersion: glassOSVersion),
    ]

    static func setting(named name: String) -> Setting? {
        all.first { $0.name == name }
    }

    /// Apps on iOS 17 and 18 reread some settings only once their `cache` notification arrives.
    private static func accessibilityToggle(_ name: String, key: String, notification: String, cache: String? = nil,
                                            defaultValue: Bool = false, minimumOSVersion: Int? = nil,
                                            service: String? = nil) -> Setting {
        let notifications = [notificationPrefix + notification] + (cache.map { [cacheNotificationPrefix + $0] } ?? [])
        let storage = Setting.Storage.preference(domain: accessibility, key: key, defaultValue: .bool(defaultValue),
                                                 notifications: notifications)
        return Setting(name: name, kind: .toggle, storage: storage, minimumOSVersion: minimumOSVersion, service: service)
    }
}
