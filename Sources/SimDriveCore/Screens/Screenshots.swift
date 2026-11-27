import CoreGraphics
import Foundation
import ImageIO
import SimDriveNative
import UniformTypeIdentifiers

/// A width and height in pixels.
struct PixelSize: Codable, Equatable, Sendable {
    let width: Int
    let height: Int

    var isLandscape: Bool { width > height }
}

/// A screenshot on disk: the image to read, and the full-resolution original when the image is downscaled.
struct Screenshot: Sendable {
    let path: String
    let image: PixelSize
    let fullPath: String
    let full: PixelSize
}

enum Screenshots {
    private static let fullExtension = "full"
    private static let pngExtension = "png"

    /// The `simctl` arguments that capture a screen as PNG. A multi-display device needs `display`.
    static func simctlArguments(udid: String, display: Int?, path: String) -> [String] {
        ["io", udid, "screenshot", "--type=\(pngExtension)"] + (display.map { ["--display=\($0)"] } ?? []) + [path]
    }

    /// Captures a screen, from `frame` when there is one and with `simctl` otherwise. When it is larger than
    /// `maxDimension` pixels, writes a downscaled copy to `path` and the original next to it. Zero keeps the original only.
    static func capture(udid: String, display: Int?, frame: ScreenFrame?, to path: String, maxDimension: Int,
                        tools: DeveloperTools) async throws -> Screenshot {
        if let frame {
            return try write(upright(frame), to: path, maxDimension: maxDimension)
        }
        let (url, fullURL) = try urls(for: path)
        try await tools.simctl(simctlArguments(udid: udid, display: display, path: fullURL.path))
        let full = try size(of: fullURL.path)
        guard maxDimension > 0, max(full.width, full.height) > maxDimension else {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: fullURL, to: url)
            return Screenshot(path: url.path, image: full, fullPath: url.path, full: full)
        }
        let image = try downscale(fullURL, to: url, maxDimension: maxDimension)
        return Screenshot(path: url.path, image: image, fullPath: fullURL.path, full: full)
    }

    /// Writes an upright image as `capture` writes a screen.
    static func write(_ image: CGImage, to path: String, maxDimension: Int) throws -> Screenshot {
        let (url, fullURL) = try urls(for: path)
        return try capture(image, url: url, fullURL: fullURL, maxDimension: maxDimension)
    }

    /// The image's file, and its full-resolution original's next to it, with their directory created.
    private static func urls(for path: String) throws -> (url: URL, fullURL: URL) {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fileExtension = url.pathExtension.isEmpty ? pngExtension : url.pathExtension
        return (url, url.deletingPathExtension().appendingPathExtension(fullExtension).appendingPathExtension(fileExtension))
    }

    /// The size of `frame` as a screenshot shows it.
    static func size(of frame: ScreenFrame) -> PixelSize {
        let size = PixelSize(width: frame.image.width, height: frame.image.height)
        return quarterTurns(for: frame.interfaceOrientation).isMultiple(of: 2) ? size : PixelSize(width: size.height, height: size.width)
    }

    /// `frame` rotated as `simctl` rotates screenshots, so that its interface reads upright.
    static func upright(_ frame: ScreenFrame) throws -> CGImage {
        let turns = quarterTurns(for: frame.interfaceOrientation)
        guard turns != 0 else {
            return frame.image
        }
        let image = frame.image
        let size = size(of: frame)
        guard let context = bitmap(size) else {
            throw SimDriveError(.screenshot, "The screen could not be rotated.")
        }
        context.translateBy(x: CGFloat(size.width) / 2, y: CGFloat(size.height) / 2)
        context.rotate(by: CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width), height: CGFloat(image.height)))
        guard let rotated = context.makeImage() else {
            throw SimDriveError(.screenshot, "The screen could not be rotated.")
        }
        return rotated
    }

    /// Counterclockwise quarter turns, in Core Graphics' upward y, that bring a portrait panel's interface upright.
    private static func quarterTurns(for orientation: InterfaceOrientation?) -> Int {
        switch orientation {
        case .portrait, nil: 0
        case .landscapeRight: 1
        case .portraitUpsideDown: 2
        case .landscapeLeft: 3
        }
    }

    private static func capture(_ image: CGImage, url: URL, fullURL: URL, maxDimension: Int) throws -> Screenshot {
        let full = PixelSize(width: image.width, height: image.height)
        guard maxDimension > 0, max(full.width, full.height) > maxDimension else {
            try write(image, to: url)
            return Screenshot(path: url.path, image: full, fullPath: url.path, full: full)
        }
        let scale = Double(maxDimension) / Double(max(full.width, full.height))
        let size = PixelSize(width: Int((Double(full.width) * scale).rounded()), height: Int((Double(full.height) * scale).rounded()))
        guard let context = bitmap(size) else {
            throw SimDriveError(.screenshotScale, "The screenshot could not be downscaled.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let scaled = context.makeImage() else {
            throw SimDriveError(.screenshotScale, "The screenshot could not be downscaled.")
        }
        try write(scaled, to: url)
        try write(image, to: fullURL)
        return Screenshot(path: url.path, image: size, fullPath: fullURL.path, full: full)
    }

    private static func bitmap(_ size: PixelSize) -> CGContext? {
        CGColorSpace(name: CGColorSpace.sRGB).flatMap { space in
            CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
    }

    private static func write(_ image: CGImage, to url: URL) throws {
        guard let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SimDriveError(.screenshotWrite, "The screenshot could not be written to \(url.path).")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else {
            throw SimDriveError(.screenshotWrite, "The screenshot could not be written to \(url.path).")
        }
    }

    static func size(of path: String) throws -> PixelSize {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw SimDriveError(.screenshotRead, "The screenshot at \(path) could not be read.")
        }
        return PixelSize(width: width, height: height)
    }

    private static func downscale(_ source: URL, to destination: URL, maxDimension: Int) throws -> PixelSize {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SimDriveError(.screenshotScale, "The screenshot could not be downscaled.")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else {
            throw SimDriveError(.screenshotScale, "The downscaled screenshot could not be written to \(destination.path).")
        }
        return PixelSize(width: image.width, height: image.height)
    }
}
