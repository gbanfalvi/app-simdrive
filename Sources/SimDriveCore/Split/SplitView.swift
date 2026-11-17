import SimDriveNative

/// Moves the frontmost app between the halves and the whole of the iPhone Duo's inner screen, as a person drags its
/// home indicator.
@MainActor
final class SplitView {
    private enum Timing {
        /// The resize animates for about half a second after the touch ends.
        static let resizeLimit: Duration = .seconds(3)
        static let poll: Duration = .milliseconds(200)
    }

    private let screens: Screens
    private let inputs: DeviceInputs
    private let accessibility: DeviceAccessibility

    init(screens: Screens, inputs: DeviceInputs, accessibility: DeviceAccessibility) {
        self.screens = screens
        self.inputs = inputs
        self.accessibility = accessibility
    }

    /// `current` overrides the layout simdrive last set, which a person may have changed since.
    func move(to target: SplitLayout, from current: SplitLayout?) async throws -> JSONValue {
        let screen = try await screens.touchscreen(.automatic, usesPixels: false)
        guard screen.display?.role == SimulatorDisplay.innerRole, screen.record.image.isLandscape else {
            throw SimDriveError(.splitUnsupported, "Split view needs an iPhone Duo's inner screen, unfolded and in landscape.")
        }
        let start = if let current { current } else { try await layout() }
        if let gesture = SplitGesture.moving(from: start, to: target) {
            try await inputs.drag(through: gesture.path.map { screen.digitizerPoint(.normalized($0)) }, duration: gesture.duration,
                                  edge: screen.mapping.digitizerEdge(.bottom), on: screen.digitizerTarget)
            try await waitForResize(to: target)
        }
        screens.splitLayout = target
        return ["display": JSONValue(screen.display?.index), "from": .string(start.rawValue), "layout": .string(target.rawValue)]
    }

    /// Accessibility tells a half from the whole screen but not which half, which only the last layout set tells.
    private func layout() async throws -> SplitLayout {
        guard try await accessibility.fillsHalf() else { return .full }
        guard let remembered = screens.splitLayout, remembered.isHalf else {
            throw SimDriveError(.splitSideUnknown, "The app fills a half that simdrive did not set; pass --from left or --from right.")
        }
        return remembered
    }

    /// A move between halves keeps the width, so only a move to or from the whole screen is checked.
    private func waitForResize(to target: SplitLayout) async throws {
        let deadline = ContinuousClock.now + Timing.resizeLimit
        while try await accessibility.fillsHalf() != target.isHalf {
            guard ContinuousClock.now < deadline else {
                throw SimDriveError(.splitDropped, "The app did not resize; take a screenshot to see what the drag did.")
            }
            try await Task.sleep(for: Timing.poll)
        }
    }
}
