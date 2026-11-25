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

    private let driver: CoreDeviceHinge
    private var observation: Task<Void, Never>?
    /// Why the last observation ended, which a wait that sees no angle reports.
    private var observationFailure: (any Error)?
    private(set) var angle: Double?

    var posture: DevicePosture? { DevicePosture(angle: angle) }

    /// Whether the hinge's CoreDevice record stopped answering, so the session opens the hinge again.
    var hasFailed: Bool { driver.hasFailed }

    private init(driver: CoreDeviceHinge) {
        self.driver = driver
    }

    /// The device's hinge, or nil when it has none. `remote` is asked for only when the device may fold.
    static func open(device: SimulatorDevice, remote: @MainActor () async throws -> CoreDeviceRemote?) async throws -> Hinge? {
        guard let driver = try await CoreDeviceHinge.open(device: device, remote: remote) else { return nil }
        let hinge = Hinge(driver: driver)
        hinge.observe()
        return hinge
    }

    /// Waits until the device reports an angle.
    func waitForReading() async throws {
        try await waitForAngle { $0 != nil }
    }

    /// Moves the hinge to `posture` and waits until it stops there.
    func set(_ posture: DevicePosture) async throws {
        try await driver.send(posture)
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
        observationFailure = nil
        observation = Task { [weak self, driver] in
            do {
                try await driver.observe { self?.angle = $0 }
            } catch {
                self?.observationFailure = error
            }
            self?.angle = nil
            self?.observation = nil
        }
    }

    private func waitForAngle(until condition: @escaping (Double?) -> Bool) async throws {
        observe()
        let reached = try await poll(every: Timing.poll, within: Timing.limit) { [self] () throws -> Bool? in
            if condition(angle) { return true }
            // An observation that failed explains a missing angle better than the timeout would.
            if let observationFailure, !(observationFailure is CancellationError) { throw observationFailure }
            return nil
        }
        guard reached == true else {
            throw SimDriveError(.postureTimeout, "The hinge did not report the expected angle; it reads \(describedAngle).")
        }
    }

    /// Waits for the hinge animation to end, which settles near but not at the requested angle.
    private func waitUntilSettled() async throws {
        let settled: Void? = try await withDeadline(Timing.limit) { [self] in
            var settledSince = ContinuousClock.now
            var lastAngle = angle
            while ContinuousClock.now - settledSince < Timing.settle {
                try await Task.sleep(for: Timing.poll)
                if angle != lastAngle {
                    lastAngle = angle
                    settledSince = .now
                }
            }
        }
        guard settled != nil else {
            throw SimDriveError(.postureTimeout, "The hinge kept moving; it reads \(describedAngle).")
        }
    }

    private var describedAngle: String { angle.map { "\($0)" } ?? "nothing" }
}
