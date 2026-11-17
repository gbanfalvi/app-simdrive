import CoreGraphics
import Foundation
import IOSurface

/// A screen's current pixels, in the panel's native orientation, with the interface orientation `simctl` rotates by.
package struct ScreenFrame: Sendable {
    package let image: CGImage
    package let interfaceOrientation: InterfaceOrientation?
}

/// The surfaces CoreSimulator renders each screen into, which `simctl io screenshot` encodes.
@MainActor
struct ScreenFramebuffers {
    private static let portIdentifier = "com.apple.framebuffer.display"
    private static let bgraPixelFormat: OSType = 0x4247_5241
    private static let bitsPerPixel = 32
    private static let poweredOn: UInt32 = 1

    private let screens: [NSObject]

    init(device: NSObject) {
        let ports = ScreenAdapter.object(device, "io").flatMap { ScreenAdapter.object($0, "ioPorts") } as? [NSObject] ?? []
        screens = ports.filter { ScreenAdapter.object($0, "portIdentifier") as? String == Self.portIdentifier }
            .compactMap { ScreenAdapter.object($0, "descriptor") }
    }

    /// Nil when the screen is missing, powered off, or in another pixel format than BGRA.
    func frame(screenID: Int) -> ScreenFrame? {
        for screen in screens {
            guard let properties = ScreenAdapter.object(screen, "screenProperties"),
                  ScreenAdapter.uint32(properties, "screenID") == UInt32(screenID) else {
                continue
            }
            guard ScreenAdapter.uint32(properties, "powerState") == Self.poweredOn,
                  let surface = ScreenAdapter.object(screen, "framebufferSurface") as? IOSurface,
                  surface.pixelFormat == Self.bgraPixelFormat, let image = Self.image(of: surface) else {
                return nil
            }
            let orientation = ScreenAdapter.uint32(properties, "uiOrientation").flatMap(InterfaceOrientation.init(screenValue:))
            return ScreenFrame(image: image, interfaceOrientation: orientation)
        }
        return nil
    }

    /// Copies the surface, which the simulator keeps drawing into.
    private static func image(of surface: IOSurface) -> CGImage? {
        guard surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else {
            return nil
        }
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let data = Data(bytes: surface.baseAddress, count: surface.bytesPerRow * surface.height)
        guard let provider = CGDataProvider(data: data as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: surface.width, height: surface.height, bitsPerComponent: 8, bitsPerPixel: bitsPerPixel,
                       bytesPerRow: surface.bytesPerRow, space: space, bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
