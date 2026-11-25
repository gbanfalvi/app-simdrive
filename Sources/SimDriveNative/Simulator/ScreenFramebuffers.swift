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
        guard let (surface, properties) = surface(screenID: screenID), let image = Self.image(of: surface) else {
            return nil
        }
        let orientation = ScreenAdapter.uint32(properties, "uiOrientation").flatMap(InterfaceOrientation.init(screenValue:))
        return ScreenFrame(image: image, interfaceOrientation: orientation)
    }

    /// The BGRA bytes of a square of `side` pixels around `unitPoint`, in the panel's native orientation, clipped to the
    /// screen. Copies only those rows, so it is cheap enough to compare every few milliseconds. Nil as `frame` is.
    func pixels(screenID: Int, around unitPoint: CGPoint, side: Int) -> [UInt8]? {
        surface(screenID: screenID).flatMap { Self.pixels(of: $0.surface, around: unitPoint, side: side) }
    }

    private func surface(screenID: Int) -> (surface: IOSurface, properties: NSObject)? {
        for screen in screens {
            guard let properties = ScreenAdapter.object(screen, "screenProperties"),
                  ScreenAdapter.uint32(properties, "screenID") == UInt32(screenID) else {
                continue
            }
            guard ScreenAdapter.uint32(properties, "powerState") == Self.poweredOn,
                  let surface = ScreenAdapter.object(screen, "framebufferSurface") as? IOSurface,
                  surface.pixelFormat == Self.bgraPixelFormat else {
                return nil
            }
            return (surface, properties)
        }
        return nil
    }

    private static func pixels(of surface: IOSurface, around unitPoint: CGPoint, side: Int) -> [UInt8]? {
        let centerX = Int(unitPoint.x * Double(surface.width)), centerY = Int(unitPoint.y * Double(surface.height))
        let left = max(0, centerX - side / 2), right = min(surface.width, centerX + side / 2)
        let top = max(0, centerY - side / 2), bottom = min(surface.height, centerY + side / 2)
        guard left < right, top < bottom, surface.lock(options: .readOnly, seed: nil) == kIOReturnSuccess else {
            return nil
        }
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytesPerPixel = bitsPerPixel / 8
        let base = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        var bytes: [UInt8] = []
        bytes.reserveCapacity((right - left) * (bottom - top) * bytesPerPixel)
        for row in top..<bottom {
            bytes.append(contentsOf: UnsafeBufferPointer(start: base + row * surface.bytesPerRow + left * bytesPerPixel,
                                                         count: (right - left) * bytesPerPixel))
        }
        return bytes
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
