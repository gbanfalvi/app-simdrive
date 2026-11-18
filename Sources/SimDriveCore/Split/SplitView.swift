import Foundation
import SimDriveNative

/// Moves the frontmost app between the halves and the whole of the iPhone Duo's inner screen, as a person drags its
/// home indicator.
@MainActor
final class SplitView {
    private enum Timing {
        /// The resize animates for about half a second after the touch ends.
        static let resizeLimit: Duration = .seconds(3)
    }

    private let screens: Screens
    private let inputs: DeviceInputs
    private let accessibility: DeviceAccessibility
    private let logs: DeviceLogs

    init(screens: Screens, inputs: DeviceInputs, accessibility: DeviceAccessibility, logs: DeviceLogs) {
        self.screens = screens
        self.inputs = inputs
        self.accessibility = accessibility
        self.logs = logs
    }

    /// `current` overrides the layout simdrive last set, which a person may have changed since.
    func move(to target: SplitLayout, from current: SplitLayout?) async throws -> JSONValue {
        let screen = try await screens.touchscreen(.automatic, usesPixels: false)
        guard screen.display?.role == SimulatorDisplay.innerRole, screen.record.image.isLandscape else {
            throw SimDriveError(.splitUnsupported, "Split view needs an iPhone Duo's inner screen, unfolded and in landscape.")
        }
        let start = if let current { current } else { try await layout() }
        if let gesture = SplitGesture.moving(from: start, to: target) {
            let dragStart = Date.now
            let shown = try await logs.entry(subsystem: DisplayLayout.subsystem, category: DisplayLayout.category,
                                             within: Timing.resizeLimit,
                                             where: { DisplayLayout(message: $0.message)?.splitLayout == target }) {
                try await inputs.drag(through: gesture.path.map { screen.digitizerPoint(.normalized($0)) }, duration: gesture.duration,
                                      edge: screen.mapping.digitizerEdge(.bottom), on: screen.digitizerTarget)
            }
            if shown == nil {
                try await confirmLayout(target, since: dragStart)
            }
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

    /// Reads the layout SpringBoard last published, for when the stream missed it.
    private func confirmLayout(_ target: SplitLayout, since start: Date) async throws {
        let shown = try await logs.entries(subsystem: DisplayLayout.subsystem, category: DisplayLayout.category, since: start)
            .compactMap { DisplayLayout(message: $0.message) }.last
        guard let shown, shown.splitLayout == target else {
            let found = shown.map { $0.splitLayout?.rawValue ?? "no split" } ?? "no layout"
            throw SimDriveError(.splitDropped, "SpringBoard shows \(found), not \(target.rawValue); take a screenshot to see what the "
                                + "drag did.")
        }
    }
}
