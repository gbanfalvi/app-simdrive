import Testing
@testable import SimDriveCore

struct SettingCatalogTests {
    private static let reduceMotion = SettingCatalog.setting(named: "reduce-motion")
    private static let glassTint = SettingCatalog.setting(named: "glass-tint")
    private static let increaseContrast = SettingCatalog.setting(named: "increase-contrast")

    @Test func namesAreUniqueKebabCase() {
        let names = SettingCatalog.all.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { $0.allSatisfy { $0.isLowercase || $0 == "-" } })
    }

    @Test func togglesTakeOnAndOff() throws {
        let setting = try #require(Self.reduceMotion)
        #expect(setting.value(parsing: "on") == true)
        #expect(setting.value(parsing: "False") == false)
        #expect(setting.value(parsing: "maybe") == nil)
    }

    @Test func choicesAndNumbersStayInRange() throws {
        #expect(SettingCatalog.appearance.value(parsing: "dark") == "dark")
        #expect(SettingCatalog.appearance.value(parsing: "dim") == nil)
        let tint = try #require(Self.glassTint)
        #expect(tint.value(parsing: "0.8") == 0.8)
        #expect(tint.value(parsing: "1.5") == nil)
        #expect(tint.value(parsing: "more") == nil)
    }

    @Test func storedPreferencesFallBackToTheirDefaults() throws {
        let reduceMotion = try #require(Self.reduceMotion)
        #expect(reduceMotion.value(stored: 1) == true)
        #expect(reduceMotion.value(stored: nil) == false)
        #expect(reduceMotion.value(stored: "yes") == false)
        #expect(SettingCatalog.setting(named: "autoplay-video-previews")?.value(stored: nil) == true)
        let tint = try #require(Self.glassTint)
        #expect(tint.value(stored: nil) == 0.5)
        #expect(tint.value(stored: 0.8) == 0.8)
        #expect(tint.value(stored: .number(Double(Float(0.8)))) == 0.8)
    }

    @Test func preferencesUseTheirDefaultsTypes() throws {
        let reduceMotion = try #require(Self.reduceMotion)
        #expect(reduceMotion.preferenceValue(true).defaultsArguments == ["-int", "1"])
        #expect(reduceMotion.preferenceValue(false).defaultsArguments == ["-int", "0"])
        #expect(try #require(Self.glassTint).preferenceValue(0.25).defaultsArguments == ["-float", "0.25"])
    }

    @Test func interfaceTogglesReadAndWriteEnabled() throws {
        let contrast = try #require(Self.increaseContrast)
        #expect(contrast.value(interfaceReading: "enabled") == true)
        #expect(contrast.value(interfaceReading: "disabled") == false)
        #expect(contrast.value(interfaceReading: "unsupported") == "unsupported")
        #expect(contrast.interfaceArgument(true) == "enabled")
        #expect(SettingCatalog.appearance.value(interfaceReading: "dark") == "dark")
        #expect(SettingCatalog.appearance.interfaceArgument("dark") == "dark")
    }

    @Test func accessibilityPreferencesNotifyRunningApps() {
        for setting in SettingCatalog.all {
            guard case .preference(_, _, _, let notifications) = setting.store else { continue }
            #expect(!notifications.isEmpty, "\(setting.name)")
        }
    }

    @Test func reduceMotionAlsoClearsTheAccessibilityCache() throws {
        guard case .preference(_, _, _, let notifications) = try #require(Self.reduceMotion).store else {
            Issue.record("reduce-motion is not a preference")
            return
        }
        #expect(notifications == ["com.apple.accessibility.reduce.motion.status", "com.apple.accessibility.cache.reduce.motion"])
    }

    @Test func newerSettingsExistFromTheirOSVersion() throws {
        let tint = try #require(Self.glassTint)
        #expect(!tint.exists(onOSVersion: 18))
        #expect(tint.exists(onOSVersion: 26))
        #expect(tint.exists(onOSVersion: nil))
        let nonBlinkingCursor = try #require(SettingCatalog.setting(named: "non-blinking-cursor"))
        #expect(nonBlinkingCursor.exists(onOSVersion: 18))
        #expect(!nonBlinkingCursor.exists(onOSVersion: 17))
        #expect(try #require(Self.reduceMotion).exists(onOSVersion: 17))
    }
}
