import SimDriveNative

/// Which half of the iPhone Duo's inner screen simdrive last moved an app to. Accessibility tells a half from the whole
/// screen but not which half, and SpringBoard's log, which does, takes seconds to read, so the side is remembered. It
/// belongs to the app it was set for, and is forgotten when that app leaves the front, the posture changes or a move
/// fails.
@MainActor
final class SplitState {
    private var layout: SplitLayout?
    private var pid: Int32?

    /// The layout simdrive set for the app of `pid`, or nil when it set none for that app.
    func layout(forApp pid: Int32?) -> SplitLayout? {
        guard let pid, pid == self.pid else { return nil }
        return layout
    }

    func remember(_ layout: SplitLayout, forApp pid: Int32?) {
        self.layout = pid == nil ? nil : layout
        self.pid = pid
    }

    func forget() {
        layout = nil
        pid = nil
    }
}
