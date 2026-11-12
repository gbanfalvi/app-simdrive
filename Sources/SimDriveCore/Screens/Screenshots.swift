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
    /// The screen ID `simctl` gives a single-display device's screen.
    private static let mainScreenID = 1

    /// The `simctl` arguments that capture a screen as PNG. A multi-display device needs `display`.
    static func simctlArguments(udid: String, display: Int?, path: String) -> [String] {
        ["io", udid, "screenshot", "--type=\(pngExtension)"] + (display.map { ["--display=\($0)"] } ?? []) + [path]
    }

    /// The interface orientation `simctl` rotates a screen's screenshots by; nil when it reports none.
    static func interfaceOrientation(udid: String, display: Int?, tools: DeveloperTools) async -> InterfaceOrientation? {
        guard let result = try? await tools.simctlResult(["io", udid, "enumerate"]), result.succeeded else { return nil }
        return InterfaceOrientation.parse(enumeration: result.standardOutput)[display ?? mainScreenID]
    }

    /// Captures a screen with `simctl` and, when it is larger than `maxDimension` pixels, writes a downscaled copy to
    /// `path` and the original next to it. Zero keeps the original only.
    static func capture(udid: String, display: Int?, to path: String, maxDimension: Int,
                        tools: DeveloperTools) async throws -> Screenshot {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fileExtension = url.pathExtension.isEmpty ? pngExtension : url.pathExtension
        let fullURL = url.deletingPathExtension().appendingPathExtension(fullExtension).appendingPathExtension(fileExtension)
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
