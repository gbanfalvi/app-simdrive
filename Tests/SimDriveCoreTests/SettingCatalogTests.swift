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
        #expect(setting.value(fromArgument: "on") == true)
        #expect(setting.value(fromArgument: "False") == false)
        #expect(setting.value(fromArgument: "maybe") == nil)
    }

    @Test func choicesAndNumbersStayInRange() throws {
        #expect(SettingCatalog.appearance.value(fromArgument: "dark") == "dark")
        #expect(SettingCatalog.appearance.value(fromArgument: "dim") == nil)
        let tint = try #require(Self.glassTint)
        #expect(tint.value(fromArgument: "0.8") == 0.8)
        #expect(tint.value(fromArgument: "1.5") == nil)
        #expect(tint.value(fromArgument: "more") == nil)
    }

    @Test func storedPreferencesFallBackToTheirDefaults() throws {
        let reduceMotion = try #require(Self.reduceMotion)
        #expect(reduceMotion.value(fromPreference: 1) == true)
        #expect(reduceMotion.value(fromPreference: nil) == false)
        #expect(reduceMotion.value(fromPreference: "yes") == false)
        #expect(SettingCatalog.setting(named: "autoplay-video-previews")?.value(fromPreference: nil) == true)
        let tint = try #require(Self.glassTint)
        #expect(tint.value(fromPreference: nil) == 0.5)
        #expect(tint.value(fromPreference: 0.8) == 0.8)
        #expect(tint.value(fromPreference: .number(Double(Float(0.8)))) == 0.8)
    }

    @Test func preferencesUseTheirDefaultsTypes() throws {
        let reduceMotion = try #require(Self.reduceMotion)
        #expect(reduceMotion.preferenceValue(for: true).defaultsArguments == ["-int", "1"])
        #expect(reduceMotion.preferenceValue(for: false).defaultsArguments == ["-int", "0"])
        #expect(try #require(Self.glassTint).preferenceValue(for: 0.25).defaultsArguments == ["-float", "0.25"])
    }

    @Test func interfaceTogglesReadAndWriteEnabled() throws {
        let contrast = try #require(Self.increaseContrast)
        #expect(contrast.value(fromInterfaceReading: "enabled") == true)
        #expect(contrast.value(fromInterfaceReading: "disabled") == false)
        #expect(contrast.value(fromInterfaceReading: "unsupported") == .unsupported)
        #expect(contrast.interfaceArgument(for: true) == "enabled")
        #expect(SettingCatalog.appearance.value(fromInterfaceReading: "dark") == "dark")
        #expect(SettingCatalog.appearance.interfaceArgument(for: "dark") == "dark")
    }

    @Test func accessibilityPreferencesNotifyRunningApps() {
        for setting in SettingCatalog.all {
            guard case .preference(_, _, _, let notifications) = setting.storage else { continue }
            #expect(!notifications.isEmpty, "\(setting.name)")
        }
    }

    @Test func reduceMotionAlsoClearsTheAccessibilityCache() throws {
        guard case .preference(_, _, _, let notifications) = try #require(Self.reduceMotion).storage else {
            Issue.record("reduce-motion is not a preference")
            return
        }
        #expect(notifications == ["com.apple.accessibility.reduce.motion.status", "com.apple.accessibility.cache.reduce.motion"])
    }

    @Test func newerSettingsAreAvailableFromTheirOSVersion() throws {
        let tint = try #require(Self.glassTint)
        #expect(!tint.isAvailable(onOSVersion: 18))
        #expect(tint.isAvailable(onOSVersion: 26))
        #expect(tint.isAvailable(onOSVersion: nil))
        let nonBlinkingCursor = try #require(SettingCatalog.setting(named: "non-blinking-cursor"))
        #expect(nonBlinkingCursor.isAvailable(onOSVersion: 18))
        #expect(!nonBlinkingCursor.isAvailable(onOSVersion: 17))
        #expect(try #require(Self.reduceMotion).isAvailable(onOSVersion: 17))
    }
}
