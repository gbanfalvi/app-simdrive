import CoreGraphics

/// A screen edge. The guest recognizes edge gestures, such as going home, only for touches that start on an edge.
package enum ScreenEdge: String, CaseIterable, Sendable { case top, bottom, left, right }

/// The panel a touch lands on. Its description is the CoreDevice `DigitizerTarget` case.
package enum DigitizerTarget: Hashable, Sendable, CustomStringConvertible {
    /// A single-display device's screen.
    case mainScreen
    /// A multi-display device's panel, by its `simctl` display index.
    case display(Int)

    package var description: String {
        switch self {
        case .mainScreen: "mainScreen"
        case .display(let index): "display\(index)"
        }
    }
}

/// A touch's phase, by CoreDevice `DigitizerEventType` case.
enum TouchPhase: String { case began = "start", moved = "position", ended = "end" }

/// The guest's Indigo digitizer, which takes touches on any of the device's panels. Points are unit coordinates of
/// the target panel in its native orientation.
@MainActor
package final class GuestTouchscreen {
    private enum Timing {
        static let tapHold: Duration = .milliseconds(60)
        /// One frame at 60 Hz, so the guest sees a drag move as smoothly as a finger.
        static let dragStep: Duration = .milliseconds(16)
    }

    private static let feature = "com.apple.coredevice.feature.remote.hid.digitizer"
    private let connection: GuestConnection
    private let codec: GuestMessageCodec

    private init(connection: GuestConnection, codec: GuestMessageCodec) {
        self.connection = connection
        self.codec = codec
    }

    package static func open(guest: SimulatorGuest) async throws -> GuestTouchscreen {
        GuestTouchscreen(connection: try await guest.connection(to: feature), codec: guest.codec)
    }

    package var hasFailed: Bool { connection.hasFailed }

    package func tap(at point: CGPoint, target: DigitizerTarget) async throws {
        try send(point, .began, edge: nil, target: target)
        await pause(Timing.tapHold)
        try send(point, .ended, edge: nil, target: target)
        try await connection.flush()
    }

    /// Drags one touch through `path` over `duration`, giving each segment equal time, so a repeated point holds.
    package func drag(through path: [CGPoint], duration: Duration, edge: ScreenEdge?, target: DigitizerTarget) async throws {
        guard let start = path.first, let end = path.last else { return }
        let segments = Array(zip(path, path.dropFirst()))
        let steps = max(1, Int((duration / Timing.dragStep).rounded()))
        let segmentSteps = max(1, steps / max(1, segments.count))
        try send(start, .began, edge: edge, target: target)
        for (from, to) in segments {
            for step in stride(from: 1, through: segmentSteps, by: 1) {
                await pause(Timing.dragStep)
                let fraction = CGFloat(step) / CGFloat(segmentSteps)
                try send(CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction), .moved,
                         edge: edge, target: target)
            }
        }
        try send(end, .ended, edge: edge, target: target)
        try await connection.flush()
    }

    package func close() async { await connection.drain() }

    private func send(_ point: CGPoint, _ phase: TouchPhase, edge: ScreenEdge?, target: DigitizerTarget) throws {
        try connection.post(.digitizerEvent, codec.digitizerEvent(at: point, phase: phase, edge: edge, target: target))
    }
}
