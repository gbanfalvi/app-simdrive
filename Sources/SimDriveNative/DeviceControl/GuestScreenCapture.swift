import CoreGraphics
import Foundation
import ImageIO

/// A physical device's screen, captured by its developer disk image's screen capture service. A simulator's screens are
/// read from CoreSimulator's framebuffers instead.
@MainActor
package final class GuestScreenCapture {
    private static let feature = "com.apple.coredevice.feature.capturescreenshot"
    /// CoreDevice's error while the display sleeps: "Display reports zero-sized native size".
    private static let displayAsleepError: Int64 = 25005
    private static let capture = GuestActions.Declaration("CaptureScreenshotActionDeclaration", readsOutput: true,
                                                          inputType: "CaptureScreenshotInput", outputType: "CaptureScreenshotOutput")

    private let actions: GuestActions

    private init(guest: Guest) {
        actions = GuestActions(guest: guest)
    }

    /// Nil when the device has no screen capture service.
    package static func open(guest: Guest) -> GuestScreenCapture? {
        guard guest.hasService(feature) else { return nil }
        return GuestScreenCapture(guest: guest)
    }

    /// The main display as it shows, its interface upright. Fails with `display-asleep` while the display sleeps.
    package func image() async throws -> CGImage {
        let output: [String: Any]
        do {
            output = try await actions.perform(Self.capture, input: ["requestedFormat": "png"])
        } catch let refusal as GuestActionRefusal where refusal.code == Self.displayAsleepError {
            throw SimDriveError(.displayAsleep, "The device's display is asleep; press a button to wake it.")
        } catch let refusal as GuestActionRefusal {
            throw SimDriveError(.screenCapture, "The device refused the screenshot (CoreDevice error \(refusal.code)): \(refusal.reason)")
        }
        // The output's image encodes to JSON as base64 PNG data.
        guard let encoded = output["image"] as? String, let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SimDriveError(.screenCapture, "The device's screenshot could not be read.")
        }
        return image
    }
}
