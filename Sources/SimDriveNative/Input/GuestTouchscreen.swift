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

    /// Connects to the digitizer and waits until the guest takes its touches.
    package static func open(guest: SimulatorGuest) async throws -> GuestTouchscreen {
        let touchscreen = GuestTouchscreen(connection: try await guest.connection(to: feature), codec: guest.codec)
        await pause(GuestInputTiming.settle)
        return touchscreen
    }

    package var hasFailed: Bool { connection.hasFailed }

    package func tap(at point: CGPoint, target: DigitizerTarget) async throws {
        try send(point, .began, edge: nil, target: target)
        await pause(Timing.tapHold)
        try send(point, .ended, edge: nil, target: target)
        try await connection.flush()
    }

    package func drag(from start: CGPoint, to end: CGPoint, duration: Duration, edge: ScreenEdge?,
                      target: DigitizerTarget) async throws {
        let steps = max(1, Int((duration / Timing.dragStep).rounded()))
        try send(start, .began, edge: edge, target: target)
        for step in 1...steps {
            await pause(Timing.dragStep)
            let fraction = CGFloat(step) / CGFloat(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            try send(point, .moved, edge: edge, target: target)
        }
        try send(end, .ended, edge: edge, target: target)
        try await connection.flush()
    }

    package func close() async { await connection.drain() }

    private func send(_ point: CGPoint, _ phase: TouchPhase, edge: ScreenEdge?, target: DigitizerTarget) throws {
        try connection.post(.digitizerEvent, codec.digitizerEvent(at: point, phase: phase, edge: edge, target: target))
    }
}
