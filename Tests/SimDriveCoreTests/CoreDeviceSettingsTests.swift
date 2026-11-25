import Foundation
import Testing
@testable import SimDriveCore

@MainActor
struct CoreDeviceSettingsTests {
    /// `GetColorFilterActionDeclaration`'s output with a protanopia filter at half intensity, as an iPhone on iOS 27.2 reported it.
    private static var filtered: [String: Any] { ["colorFilter": ["enabled": true, "filterType": ["name": "Protanopia"], "intensity": 0.5]] }
    private static var grayscale: [String: Any] { ["colorFilter": ["enabled": true, "filterType": ["name": "Grayscale"]]] }
    /// Stands in for the native filter type's JSON, so the tests see which type went in.
    private static let context = { (current: [String: Any]) in
        CoreDeviceSetting.Context(current: current, filterType: { ["name": $0] })
    }

    @Test func theColorFilterReadsAsItsLowercasedTypeOrOff() {
        #expect(CoreDeviceSetting.colorFilter.value(in: Self.filtered) == "protanopia")
        #expect(CoreDeviceSetting.colorFilter.value(in: ["colorFilter": ["enabled": false]]) == "off")
        #expect(CoreDeviceSetting.colorFilterIntensity.value(in: Self.filtered) == 0.5)
    }

    @Test func voiceOverReadsItsConfiguration() {
        #expect(CoreDeviceSetting.voiceOver.value(in: ["voiceOverConfiguration": ["enabled": true]]) == true)
        #expect(CoreDeviceSetting.voiceOver.value(in: [:]) == .unsupported)
    }

    @Test func valuesBecomeActionInputs() async throws {
        let voiceOver = try await CoreDeviceSetting.voiceOver.input(for: true)
        #expect(Self.json(voiceOver) == Self.json(["voiceOverConfiguration": ["enabled": true]]))
        let off = try await CoreDeviceSetting.colorFilter.input(for: "off")
        #expect(Self.json(off) == Self.json(["colorFilter": ["enabled": false]]))
        #expect(try await CoreDeviceSetting.colorFilter.input(for: "sepia") == nil)
    }

    /// The input carries type and intensity together, so changing one keeps the other.
    @Test func aTypeKeepsTheIntensityAndAnIntensityKeepsTheType() async throws {
        let type = try await CoreDeviceSetting.colorFilter.input(for: "tritanopia", in: Self.context(Self.filtered))
        #expect(Self.json(type) == Self.json(["colorFilter": ["enabled": true, "filterType": ["name": "tritanopia"], "intensity": 0.5]]))
        let intensity = try await CoreDeviceSetting.colorFilterIntensity.input(for: 0.75, in: Self.context(Self.filtered))
        #expect(Self.json(intensity) == Self.json(["colorFilter": ["enabled": true, "filterType": ["name": "protanopia"], "intensity": 0.75]]))
    }

    /// The guest refuses an intensity for grayscale, and there is none without a filter.
    @Test func grayscaleAndNoFilterTakeNoIntensity() async throws {
        let toGrayscale = try await CoreDeviceSetting.colorFilter.input(for: "grayscale", in: Self.context(Self.filtered))
        #expect(Self.json(toGrayscale) == Self.json(["colorFilter": ["enabled": true, "filterType": ["name": "grayscale"]]]))
        #expect(try await CoreDeviceSetting.colorFilterIntensity.input(for: 0.75, in: Self.context(Self.grayscale)) == nil)
        #expect(try await CoreDeviceSetting.colorFilterIntensity.input(for: 0.75, in: Self.context(["colorFilter": ["enabled": false]])) == nil)
    }

    private static func json(_ object: [String: Any]?) -> String? {
        object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }.map { String(decoding: $0, as: UTF8.self) }
    }
}
