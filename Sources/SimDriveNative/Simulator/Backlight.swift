/// A screen's backlight as CoreSimulator's screen properties report it. An idle iPhone's display dims, then turns off,
/// as SpringBoard's idle timer allows.
package enum Backlight: String, Sendable {
    case on, dimmed, off, unknown

    /// CoreSimulator's `backlight.state`: 2 on, 1 dimmed, 0 off, and -101 before the screen has started.
    init(state: Int32) {
        switch state {
        case 2: self = .on
        case 1: self = .dimmed
        case 0: self = .off
        default: self = .unknown
        }
    }
}
