import CoreGraphics
import Testing
@testable import SimDriveCore
@testable import SimDriveNative

struct ScreenshotRotationTests {
    private static let width = 2
    private static let height = 3
    private static let marked: UInt8 = 255

    /// A portrait image, black but for its top-left pixel.
    private static func portrait() -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels[0...3] = [marked, marked, marked, marked]
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    /// The row and column, from the top left, of the image's one bright pixel.
    private static func markedPixel(of image: CGImage) -> (row: Int, column: Int)? {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let index = stride(from: 0, to: pixels.count, by: 4).first { pixels[$0] > marked / 2 }
        return index.map { (row: $0 / 4 / image.width, column: $0 / 4 % image.width) }
    }

    @Test func landscapeSwapsTheSize() {
        let image = Self.portrait()
        #expect(Screenshots.size(of: ScreenFrame(image: image, interfaceOrientation: .portrait)) == PixelSize(width: 2, height: 3))
        #expect(Screenshots.size(of: ScreenFrame(image: image, interfaceOrientation: nil)) == PixelSize(width: 2, height: 3))
        #expect(Screenshots.size(of: ScreenFrame(image: image, interfaceOrientation: .landscapeLeft)) == PixelSize(width: 3, height: 2))
        #expect(Screenshots.size(of: ScreenFrame(image: image, interfaceOrientation: .landscapeRight)) == PixelSize(width: 3, height: 2))
    }

    @Test func rotatesAsSimctlDoes() throws {
        let image = Self.portrait()
        let cases: [(InterfaceOrientation?, row: Int, column: Int)] = [
            (nil, 0, 0), (.portrait, 0, 0), (.landscapeRight, 1, 0), (.landscapeLeft, 0, 2), (.portraitUpsideDown, 2, 1),
        ]
        for (orientation, row, column) in cases {
            let upright = try Screenshots.upright(ScreenFrame(image: image, interfaceOrientation: orientation))
            let pixel = Self.markedPixel(of: upright)
            #expect(pixel?.row == row && pixel?.column == column, "\(String(describing: orientation)): \(String(describing: pixel))")
        }
    }
}
