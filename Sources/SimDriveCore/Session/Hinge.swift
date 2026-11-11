import SimDriveNative

/// A foldable's hinge: the angle its device reports, and waits for that angle to reach and settle at a posture.
@MainActor
final class Hinge {
    private enum Timing {
        static let limit: Duration = .seconds(15)
        static let poll: Duration = .milliseconds(100)
        /// How long the angle must hold still for the hinge animation to count as finished.
        static let settle: Duration = .milliseconds(400)
    }

    private let transport: CoreDeviceHinge
    private var observation: Task<Void, Never>?
    private(set) var angle: Double?

    var posture: DevicePosture? { DevicePosture(angle: angle) }

    private init(transport: CoreDeviceHinge) {
        self.transport = transport
    }

    /// The hinge of `remote`'s device, or nil when it has none.
    static func open(remote: CoreDeviceRemote) async throws -> Hinge? {
        guard let transport = try await CoreDeviceHinge.open(remote: remote) else { return nil }
        let hinge = Hinge(transport: transport)
        hinge.observe()
        return hinge
    }

    /// Waits until the device reports an angle.
    func waitForReading() async throws {
        try await waitForAngle { $0 != nil }
    }

    /// Moves the hinge to `posture` and waits until it stops there.
    func set(_ posture: DevicePosture) async throws {
        try await transport.send(posture)
        try await waitForAngle { DevicePosture(angle: $0) == posture }
        try await waitUntilSettled()
    }

    func stop() {
        observation?.cancel()
        observation = nil
    }

    /// Follows the angle until the device stops reporting it; the next wait follows it again.
    private func observe() {
        guard observation == nil else { return }
        observation = Task { [weak self, transport] in
            try? await transport.observe { self?.angle = $0 }
            self?.angle = nil
            self?.observation = nil
        }
    }

    private func waitForAngle(until condition: (Double?) -> Bool) async throws {
        observe()
        let deadline = ContinuousClock.now + Timing.limit
        while !condition(angle) {
            guard ContinuousClock.now < deadline else {
                throw SimDriveError(.postureTimeout, "The hinge did not report the expected angle; it reads \(describedAngle).")
            }
            try await Task.sleep(for: Timing.poll)
        }
    }

    /// Waits for the hinge animation to end, which settles near but not at the requested angle.
    private func waitUntilSettled() async throws {
        let deadline = ContinuousClock.now + Timing.limit
        var settledSince = ContinuousClock.now
        var lastAngle = angle
        while ContinuousClock.now - settledSince < Timing.settle {
            guard ContinuousClock.now < deadline else {
                throw SimDriveError(.postureTimeout, "The hinge kept moving; it reads \(describedAngle).")
            }
            try await Task.sleep(for: Timing.poll)
            if angle != lastAngle {
                lastAngle = angle
                settledSince = .now
            }
        }
    }

    private var describedAngle: String { angle.map { "\($0)" } ?? "nothing" }
}
