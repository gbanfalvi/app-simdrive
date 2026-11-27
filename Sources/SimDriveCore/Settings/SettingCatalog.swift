import SimDriveNative

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
        /// An option CoreSimulator changes itself.
        case interface(SimulatorDevice.InterfaceOption)
        /// A guest preference, and the Darwin notifications that tell running apps it changed. `defaultValue` applies
        /// while the key is unset.
        case preference(domain: String, key: String, defaultValue: JSONValue, notifications: [String])
        /// A setting the guest applies through CoreDevice's setting actions.
        case coreDevice(CoreDeviceSetting)
        /// A Darwin notification's state in the guest, 1 for on, which UIKit rereads when it is posted. Available where
        /// the device supports `feature`, CoreSimulator's word that the guest keeps the state.
        case notificationState(name: String, feature: String)
    }

    private static let toggleNames: [String: Bool] = ["on": true, "off": false, "true": true, "false": false]
    private static let onChoice = "on"
    private static let offChoice = "off"
    /// Preferences keep numbers as 32-bit floats; four decimals drop their rounding error.
    private static let numberPrecision = 10_000.0

    let name: String
    let kind: Kind
    /// Where the setting is kept, in order of preference: a device uses the first it can reach. A simulator reaches every
    /// kind; a physical device only CoreDevice's setting actions.
    let storages: [Storage]
    let minimumOSVersion: Int?
    /// The guest's on-demand launchd daemon that Settings starts when the setting turns on; the setting needs it.
    let service: String?

    /// `action` keeps the setting where `storage` cannot be reached, as on a physical device.
    init(name: String, kind: Kind, storage: Storage, action: CoreDeviceSetting? = nil, minimumOSVersion: Int? = nil,
         service: String? = nil) {
        self.name = name
        self.kind = kind
        storages = [storage] + (action.map { [.coreDevice($0)] } ?? [])
        self.minimumOSVersion = minimumOSVersion
        self.service = service
    }

    /// The storage a simulator uses.
    var storage: Storage { storages[0] }

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

    /// The value of an interface option's choice, which is nil when the device lacks the option. A toggle's choices are
    /// `off` and `on`.
    func value(fromInterfaceChoice choice: String?) -> JSONValue {
        switch (kind, choice) {
        case (.toggle, let choice?): return .bool(choice == Self.onChoice)
        case (.choice(let choices), let choice?) where choices.contains(choice): return .string(choice)
        default: return .unsupported
        }
    }

    func interfaceChoice(for value: JSONValue) -> String? {
        switch (kind, value) {
        case (.toggle, .bool(let isOn)): isOn ? Self.onChoice : Self.offChoice
        case (.choice(let choices), .string(let choice)) where choices.contains(choice): choice
        default: nil
        }
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
    /// The guest reads a color filter on iOS 17 and 26 but refuses to change one before iOS 27 (CoreDevice error 21049).
    private static let colorFilterOSVersion = 27
    private static let fullKeyboardAccessService = "com.apple.fullkeyboardaccess"
    static let appearance = Setting(name: "appearance", kind: .choice(SimulatorDevice.InterfaceOption.appearance.choices),
                                    storage: .interface(.appearance), action: .appearance)

    /// Not a setting of its own: Settings turns it on before starting a setting's service, so running apps answer that service,
    /// and `launch` before launching, so the app answers `tree`. backboardd turns it off when its last client, such as that
    /// service, quits.
    static let applicationAccessibility = accessibilityToggle("application-accessibility", key: "ApplicationAccessibilityEnabled",
                                                              notification: "application.status", cache: "app.ax")

    static let all: [Setting] = [
        appearance,
        Setting(name: "text-size", kind: .choice(SimulatorDevice.InterfaceOption.textSize.choices), storage: .interface(.textSize),
                action: .textSize),
        Setting(name: "increase-contrast", kind: .toggle, storage: .interface(.increaseContrast), action: .increaseContrast),
        accessibilityToggle("bold-text", key: "EnhancedTextLegibilityEnabled", notification: "text.legibility.status",
                            cache: "enhance.text.legibility"),
        accessibilityToggle("reduce-motion", key: "ReduceMotionEnabled", notification: "reduce.motion.status", cache: "reduce.motion",
                            action: .reduceMotion),
        accessibilityToggle("prefer-cross-fade", key: "ReduceMotionReduceSlideTransitionsPreference",
                            notification: "reduce.motion.reduce.slide.transitions.status", cache: "reduce.motion.reduce.slide.transitions"),
        accessibilityToggle("reduce-transparency", key: "EnhancedBackgroundContrastEnabled",
                            notification: "enhance.background.contrast.status", cache: "enhance.background.contrast",
                            action: .reduceTransparency),
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
        Setting(name: "voiceover", kind: .toggle, storage: .coreDevice(.voiceOver)),
        // As Simulator's Debug > Slow Animations: UIKit slows every app's animations.
        Setting(name: "slow-animations", kind: .toggle, storage: .notificationState(
            name: "com.apple.UIKit.SimulatorSlowMotionAnimationState", feature: "com.apple.UIKit.SimulatorSlowMotionStateful")),
        Setting(name: "color-filter", kind: .choice([CoreDeviceSetting.colorFilterOff] + CoreDeviceSetting.colorFilterTypes),
                storage: .coreDevice(.colorFilter), minimumOSVersion: colorFilterOSVersion),
        Setting(name: "color-filter-intensity", kind: .number(0.25...1), storage: .coreDevice(.colorFilterIntensity),
                minimumOSVersion: colorFilterOSVersion),
    ]

    static func setting(named name: String) -> Setting? {
        all.first { $0.name == name }
    }

    /// Apps on iOS 17 and 18 reread some settings only once their `cache` notification arrives.
    private static func accessibilityToggle(_ name: String, key: String, notification: String, cache: String? = nil,
                                            defaultValue: Bool = false, action: CoreDeviceSetting? = nil,
                                            minimumOSVersion: Int? = nil, service: String? = nil) -> Setting {
        let notifications = [notificationPrefix + notification] + (cache.map { [cacheNotificationPrefix + $0] } ?? [])
        let storage = Setting.Storage.preference(domain: accessibility, key: key, defaultValue: .bool(defaultValue),
                                                 notifications: notifications)
        return Setting(name: name, kind: .toggle, storage: storage, action: action, minimumOSVersion: minimumOSVersion,
                       service: service)
    }
}
