import CoreGraphics
import Foundation
import ABIBridge

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
    /// `CaptureScreenshotOutput.image`, read from the decoded output rather than through JSON, which would re-encode the
    /// image as base64 PNG.
    private let readImage: (NativeSwiftValue) throws -> CGImage

    private init(guest: Guest, readImage: @escaping (NativeSwiftValue) throws -> CGImage) {
        actions = GuestActions(guest: guest)
        self.readImage = readImage
    }

    /// Nil when the device has no screen capture service.
    package static func open(guest: Guest) async throws -> GuestScreenCapture? {
        guard guest.hasService(feature) else { return nil }
        let image = try await ABIRuntime.shared.prepare { runtime in
            let output = try await runtime.resolve(.swift(.type("CoreDeviceUtilities.CaptureScreenshotOutput")))
            let abis = try NativeType.opaqueABIs(for: [output])
            // Bound as AnyObject: ABIBridge's reference check crashed on the CGImage type itself.
            return try await output.resolve(.swift(.getter("image", as: (() -> AnyObject).self, valueABIs: abis, receiverABI: abis[output])))
        }
        return GuestScreenCapture(guest: guest) { value in
            let object = try unsafe image.unsafeInvoke(on: value)
            guard CFGetTypeID(object) == CGImage.typeID else { throw SimDriveError(.screenCapture, "The device's screenshot is not an image.") }
            return unsafe unsafeBitCast(object, to: CGImage.self)
        }
    }

    /// The main display as it shows, its interface upright. Fails with `display-asleep` while the display sleeps.
    package func image() async throws -> CGImage {
        let output: NativeSwiftValue?
        do {
            output = try await actions.performNative(Self.capture, input: ["requestedFormat": "png"])
        } catch let refusal as GuestActionRefusal where refusal.code == Self.displayAsleepError {
            throw SimDriveError(.displayAsleep, "The device's display is asleep; press a button to wake it.")
        } catch let refusal as GuestActionRefusal {
            throw SimDriveError(.screenCapture, "The device refused the screenshot (CoreDevice error \(refusal.code)): \(refusal.reason)")
        }
        guard let output else { throw SimDriveError(.screenCapture, "The device's screenshot had no image.") }
        return try readImage(output)
    }
}
