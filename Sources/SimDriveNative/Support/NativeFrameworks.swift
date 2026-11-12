import Darwin
import Foundation

/// Loads private frameworks on one serial queue. Libraries stay mapped for the process lifetime.
enum NativeFrameworks {
    private static let queue = DispatchQueue(label: "simdrive.native-frameworks")

    static let coreSimulatorPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
    static let coreDevicePath = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice"
    static let accessibilityTranslationPath =
        "/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation"

    static func load(_ path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { continuation.resume(with: Result { try loadSynchronously(path) }) }
        }
    }

    static func loadSynchronously(_ path: String) throws {
        // Objective-C class registration and Swift runtime metadata outlive the handle.
        guard dlopen(path, RTLD_NOW | RTLD_LOCAL) != nil else {
            let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
            throw SimDriveError(.frameworkLoad, "Could not load \(path): \(detail)")
        }
    }
}
