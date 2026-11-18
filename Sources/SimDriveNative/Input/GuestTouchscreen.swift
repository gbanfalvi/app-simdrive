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

    /// Waits out a new connection's 200 ms first-message delay, which would bunch a drag's first touches into a swipe.
    package static func open(guest: SimulatorGuest) async throws -> GuestTouchscreen {
        let connection = try await guest.connection(to: feature)
        try await connection.flush()
        return GuestTouchscreen(connection: connection, codec: guest.codec)
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
        try await drag([path], duration: duration, edge: edge, target: target)
    }

    /// Drags two touches together, each through its own path; the paths have as many points.
    package func drag(through first: [CGPoint], and second: [CGPoint], duration: Duration, target: DigitizerTarget) async throws {
        try await drag([first, second], duration: duration, edge: nil, target: target)
    }

    private func drag(_ paths: [[CGPoint]], duration: Duration, edge: ScreenEdge?, target: DigitizerTarget) async throws {
        guard let path = paths.first, !path.isEmpty else { return }
        let segments = path.count - 1
        let steps = max(1, Int((duration / Timing.dragStep).rounded()))
        let segmentSteps = max(1, steps / max(1, segments))
        try send(paths.map { $0[0] }, .began, edge: edge, target: target)
        for segment in 0..<segments {
            for step in stride(from: 1, through: segmentSteps, by: 1) {
                await pause(Timing.dragStep)
                let fraction = CGFloat(step) / CGFloat(segmentSteps)
                try send(paths.map { path in
                    let (from, to) = (path[segment], path[segment + 1])
                    return CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
                }, .moved, edge: edge, target: target)
            }
        }
        try send(paths.map { $0[segments] }, .ended, edge: edge, target: target)
        try await connection.flush()
    }

    package func close() async { await connection.drain() }

    private func send(_ point: CGPoint, _ phase: TouchPhase, edge: ScreenEdge?, target: DigitizerTarget) throws {
        try send([point], phase, edge: edge, target: target)
    }

    private func send(_ fingers: [CGPoint], _ phase: TouchPhase, edge: ScreenEdge?, target: DigitizerTarget) throws {
        try connection.post(.digitizerEvent, codec.digitizerEvent(at: fingers[0], second: fingers.dropFirst().first, phase: phase,
                                                                  edge: edge, target: target))
    }
}
