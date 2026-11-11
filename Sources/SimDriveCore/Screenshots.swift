import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A screen's last screenshot, which pixel coordinates and the screen's rotation refer to.
package struct ScreenRecord: Codable, Equatable, Sendable {
    /// Full-resolution pixels.
    package let width: Int
    package let height: Int
    /// Pixels of the image the caller reads, which may be downscaled.
    package let imageWidth: Int
    package let imageHeight: Int
    package let orientation: DeviceOrientation

    package var isLandscape: Bool { width > height }
}

/// Each screen's last screenshot record, kept in a file so one-shot runs share them.
@MainActor
package final class ScreenStore {
    private let url: URL
    private var records: [String: ScreenRecord]

    package init(url: URL) {
        self.url = url
        records = (try? JSONDecoder().decode([String: ScreenRecord].self, from: Data(contentsOf: url))) ?? [:]
    }

    package func record(for screen: String) -> ScreenRecord? { records[screen] }

    package func save(_ record: ScreenRecord, for screen: String) {
        records[screen] = record
        persist()
    }

    /// Forgets every screen, since a new foreground app may rotate the interface without rotating the device.
    package func removeAll() {
        records = [:]
        persist()
    }

    private func persist() {
        try? JSONEncoder.line.encode(records).write(to: url, options: .atomic)
    }
}

/// A screenshot on disk: the image to read, and the full-resolution original when the image is downscaled.
package struct Screenshot: Sendable {
    package let path: String
    package let width: Int
    package let height: Int
    package let fullPath: String
    package let fullWidth: Int
    package let fullHeight: Int
}

package enum Screenshots {
    private static let fullExtension = "full"
    private static let pngExtension = "png"

    /// Captures a screen with `simctl` and, when it is larger than `maxDimension` pixels, writes a downscaled copy to
    /// `path` and the original next to it. Zero keeps the original only.
    package static func capture(udid: String, display: Int?, to path: String, maxDimension: Int,
                                tools: ToolRunner) async throws -> Screenshot {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fileExtension = url.pathExtension.isEmpty ? pngExtension : url.pathExtension
        let fullURL = url.deletingPathExtension().appendingPathExtension(fullExtension).appendingPathExtension(fileExtension)
        var arguments = ["io", udid, "screenshot", "--type=\(pngExtension)"]
        if let display { arguments.append("--display=\(display)") }
        try await tools.checkedSimctl(arguments + [fullURL.path])
        let (fullWidth, fullHeight) = try size(of: fullURL)
        guard maxDimension > 0, max(fullWidth, fullHeight) > maxDimension else {
            try? FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: fullURL, to: url)
            return Screenshot(path: url.path, width: fullWidth, height: fullHeight, fullPath: url.path,
                              fullWidth: fullWidth, fullHeight: fullHeight)
        }
        let (width, height) = try downscale(fullURL, to: url, maxDimension: maxDimension)
        return Screenshot(path: url.path, width: width, height: height, fullPath: fullURL.path,
                          fullWidth: fullWidth, fullHeight: fullHeight)
    }

    private static func size(of url: URL) throws -> (Int, Int) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            throw SimDriveError("screenshot-read", "The screenshot at \(url.path) could not be read.")
        }
        return (width, height)
    }

    private static func downscale(_ source: URL, to destination: URL, maxDimension: Int) throws -> (Int, Int) {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
        ]
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
              let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw SimDriveError("screenshot-scale", "The screenshot could not be downscaled.")
        }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else {
            throw SimDriveError("screenshot-scale", "The downscaled screenshot could not be written to \(destination.path).")
        }
        return (image.width, image.height)
    }
}
