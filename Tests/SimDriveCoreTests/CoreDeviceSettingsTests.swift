import Testing
@testable import SimDriveCore

struct CoreDeviceSettingsTests {
    /// `devicectl device info appearance` with a protanopia filter at half intensity, as an iPhone on iOS 27.2 reported it.
    private static var filtered: [String: Any] { ["colorFilter": ["enabled": true, "filterType": ["name": "Protanopia"], "intensity": 0.5]] }

    @Test func theColorFilterReadsAsItsLowercasedTypeOrOff() {
        #expect(CoreDeviceSetting.colorFilter.value(in: Self.filtered) == "protanopia")
        #expect(CoreDeviceSetting.colorFilter.value(in: ["colorFilter": ["enabled": false]]) == "off")
        #expect(CoreDeviceSetting.colorFilterIntensity.value(in: Self.filtered) == 0.5)
    }

    @Test func voiceOverReadsItsEnabledFlag() {
        #expect(CoreDeviceSetting.voiceOver.value(in: ["enabled": true, "operation": "query"]) == true)
        #expect(CoreDeviceSetting.voiceOver.value(in: [:]) == .unsupported)
    }

    @Test func valuesBecomeDevicectlArguments() {
        #expect(CoreDeviceSetting.voiceOver.arguments(for: true) == ["voiceover", "--enable"])
        #expect(CoreDeviceSetting.colorFilter.arguments(for: "tritanopia")
            == ["appearance", "--color-filter", "on", "--color-filter-type", "tritanopia"])
        #expect(CoreDeviceSetting.colorFilter.arguments(for: "off") == ["appearance", "--color-filter", "off"])
        #expect(CoreDeviceSetting.colorFilter.arguments(for: "sepia") == nil)
    }

    /// devicectl takes an intensity only together with a filter type, so the current one goes with it.
    @Test func anIntensityCarriesTheCurrentFilterType() {
        #expect(CoreDeviceSetting.colorFilterIntensity.arguments(for: 0.75, current: Self.filtered)
            == ["appearance", "--color-filter", "on", "--color-filter-type", "protanopia", "--color-filter-intensity", "0.75"])
        #expect(CoreDeviceSetting.colorFilterIntensity.arguments(for: 0.75, current: ["colorFilter": ["enabled": false]]) == nil)
    }
}
