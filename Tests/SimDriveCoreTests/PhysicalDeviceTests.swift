import Foundation
import SimDriveNative
import Testing
@testable import SimDriveCore

/// Naming physical devices, and the settings they reach through CoreDevice's actions.
@MainActor
struct PhysicalDeviceTests {
    /// Made-up records shaped as CoreDevice lists an iPhone 15 Pro and an Apple TV 4K on 27.2.1: a newer iPhone's hardware
    /// UDID has a dash, an older device's is 40 hex digits.
    private static let iPhone = PhysicalDeviceRecord(identifier: UUID(uuidString: "1A2B3C4D-1111-5222-8333-444455556666")!,
                                                     name: "Test iPhone", udid: "00008130-000A1B2C3D4E5F6A", productType: "iPhone16,1",
                                                     osVersion: "27.2.1", isConnected: true)
    private static let appleTV = PhysicalDeviceRecord(identifier: UUID(uuidString: "9F8E7D6C-AAAA-5BBB-9CCC-DDDDEEEEFFFF")!,
                                                      name: "Test Apple TV", udid: "0123456789abcdef0123456789abcdef01234567",
                                                      productType: "AppleTV14,1", osVersion: "27.2.1", isConnected: true)

    @Test func aDeviceIsNamedByItsIdentifierOrHardwareUDID() {
        let devices = [Self.iPhone, Self.appleTV]
        let iPhone = DeviceTarget(kind: .physical, id: "1A2B3C4D-1111-5222-8333-444455556666")
        #expect(Devices.target(named: "1a2b3c4d-1111-5222-8333-444455556666", among: devices) == iPhone)
        #expect(Devices.target(named: "00008130-000A1B2C3D4E5F6A", among: devices) == iPhone)
        #expect(Devices.target(named: "Test iPhone", among: devices) == nil)
        #expect(Devices.target(named: "0123456789ABCDEF0123456789ABCDEF01234567", among: devices)?.id == "9F8E7D6C-AAAA-5BBB-9CCC-DDDDEEEEFFFF")
    }

    @Test func anAppleTVHasNoTouchscreenAndRuntimesAreNamedAsSimulatorsAre() {
        #expect(Self.appleTV.isAppleTV && !Self.iPhone.isAppleTV)
        #expect(Self.iPhone.majorOSVersion == 27)
        #expect(Devices.runtime(of: Self.iPhone) == "iOS-27-2-1")
        #expect(Devices.runtime(of: Self.appleTV) == "tvOS-27-2-1")
    }

    @Test func textSizesMapBetweenTheCatalogAndCoreDevice() {
        for name in SimulatorDevice.InterfaceOption.textSize.choices {
            #expect(CoreDeviceSetting.textSizeName(ofCase: CoreDeviceSetting.textSizeCase(ofName: name)) == name)
        }
        #expect(CoreDeviceSetting.textSizeCase(ofName: "accessibility-extra-large") == "accessibilityExtraLarge")
        #expect(CoreDeviceSetting.textSizeName(ofCase: "extraSmall") == "extra-small")
    }

    /// Outputs as an iPhone on iOS 27.2.1 returned them, and inputs as an iPhone 17 simulator on iOS 27.2 accepted them.
    @Test func appearanceSettingsReadAndWriteTheirActions() async throws {
        #expect(CoreDeviceSetting.appearance.value(in: ["style": "light"]) == "light")
        #expect(CoreDeviceSetting.textSize.value(in: ["textSize": ["size": ["extraSmall": [String: Any]()]]]) == "extra-small")
        #expect(CoreDeviceSetting.increaseContrast.value(in: ["increaseContrast": ["enabled": true]]) == true)
        #expect(CoreDeviceSetting.reduceMotion.value(in: [:]) == .unsupported)
        #expect(Self.json(try await CoreDeviceSetting.appearance.input(for: "dark")) == Self.json(["style": "dark"]))
        #expect(Self.json(try await CoreDeviceSetting.textSize.input(for: "large"))
                == Self.json(["textSize": ["size": ["large": [String: Any]()]]]))
        #expect(Self.json(try await CoreDeviceSetting.reduceTransparency.input(for: false))
                == Self.json(["reduceTransparency": ["enabled": false]]))
        #expect(try await CoreDeviceSetting.reduceMotion.input(for: "on") == nil)
    }

    /// A physical device reaches only these rows, through their actions; a simulator keeps them where it did.
    @Test func settingsAPhysicalDeviceReaches() {
        let reachable = SettingCatalog.all.filter { setting in
            setting.storages.contains { if case .coreDevice = $0 { true } else { false } }
        }.map(\.name)
        #expect(reachable == ["appearance", "text-size", "increase-contrast", "reduce-motion", "reduce-transparency", "voiceover",
                              "color-filter", "color-filter-intensity"])
        #expect(SettingCatalog.appearance.storage == .interface(.appearance))
    }

    private static func json(_ object: [String: Any]?) -> String? {
        object.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }.map { String(decoding: $0, as: UTF8.self) }
    }
}
