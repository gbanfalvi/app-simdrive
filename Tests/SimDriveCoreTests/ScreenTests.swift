import CoreGraphics
import Foundation
import SimDriveNative
import Testing
@testable import SimDriveCore

@MainActor
struct ScreenTests {
    private static let portrait = ScreenshotRecord(full: PixelSize(width: 2000, height: 4000), image: PixelSize(width: 500, height: 1000),
                                                   orientation: .portrait, interfaceOrientation: .portrait)
    private static let cover = SimulatorDisplay(index: 1, name: "LCD", role: SimulatorDisplay.coverRole,
                                                nativeSize: PixelSize(width: 1398, height: 2034))

    private let screen = Screen(display: nil, record: portrait, mapping: ScreenMapping(isRotated: false, orientation: .portrait))
    private let storeURL = FileManager.default.temporaryDirectory.appendingPathComponent("simdrive-\(UUID().uuidString).json")

    @Test func pixelsReferToTheDownscaledImage() {
        #expect(screen.normalizedPoint(.pixels(CGPoint(x: 125, y: 250))) == CGPoint(x: 0.25, y: 0.25))
    }

    @Test func pointsOutsideTheScreenAreClamped() {
        #expect(screen.normalizedPoint(.pixels(CGPoint(x: 600, y: 2000))) == CGPoint(x: 1, y: 1))
    }

    @Test func singleScreensTargetTheMainScreen() {
        #expect(screen.digitizerTarget == .mainScreen)
        #expect(DigitizerTarget(display: Self.cover) == .display(1))
    }

    @Test func storesKeepDisplaysAndRecordsAcrossRuns() {
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let bootedAt = Date(timeIntervalSinceReferenceDate: 800_000_000.123)
        let store = ScreenStore(url: storeURL, bootedAt: bootedAt)
        #expect(store.displays == nil)
        store.displays = [Self.cover]
        store.save(Self.portrait, for: .display(1))
        let reopened = ScreenStore(url: storeURL, bootedAt: bootedAt)
        #expect(reopened.displays == [Self.cover])
        #expect(reopened.record(for: .display(1)) == Self.portrait)
        reopened.removeRecords()
        #expect(ScreenStore(url: storeURL, bootedAt: bootedAt).displays == [Self.cover])
        #expect(ScreenStore(url: storeURL, bootedAt: bootedAt).record(for: .display(1)) == nil)
    }

    @Test func aRebootForgetsDisplaysAndRecords() {
        defer { try? FileManager.default.removeItem(at: storeURL) }
        let store = ScreenStore(url: storeURL, bootedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        store.displays = []
        store.save(Self.portrait, for: .mainScreen)
        let rebooted = ScreenStore(url: storeURL, bootedAt: Date(timeIntervalSinceReferenceDate: 800_000_600))
        #expect(rebooted.displays == nil)
        #expect(rebooted.record(for: .mainScreen) == nil)
    }
}
