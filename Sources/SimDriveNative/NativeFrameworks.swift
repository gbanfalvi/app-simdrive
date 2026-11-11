import Darwin
import Foundation

/// Loads private frameworks on one serial queue. Libraries stay mapped for the process lifetime.
package enum NativeFrameworks {
    private static let queue = DispatchQueue(label: "simdrive.native-frameworks")

    package static let coreSimulatorPath = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
    package static let coreDevicePath = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/CoreDevice"

    package static func load(_ path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { continuation.resume(with: Result { try loadSynchronously(path) }) }
        }
    }

    package static func loadSynchronously(_ path: String) throws {
        // Objective-C class registration and Swift runtime metadata outlive the handle.
        guard dlopen(path, RTLD_NOW | RTLD_LOCAL) != nil else {
            let detail = dlerror().map { String(cString: $0) } ?? "unknown loader error"
            throw NativeError("framework-load", "Could not load \(path): \(detail)")
        }
    }
}
