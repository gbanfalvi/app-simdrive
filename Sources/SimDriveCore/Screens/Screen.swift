import CoreGraphics
import SimDriveNative

/// A display, with the screenshot its points refer to and how those points map to the digitizer.
struct Screen: Sendable {
    let display: SimulatorDisplay?
    let record: ScreenshotRecord
    let mapping: ScreenMapping

    var digitizerTarget: DigitizerTarget { DigitizerTarget(display: display) }

    /// The point as fractions of the screenshot, clamped to the screen.
    func normalizedPoint(_ point: ScreenPoint) -> CGPoint {
        let normalized = switch point {
        case .normalized(let value): value
        case .pixels(let value):
            CGPoint(x: value.x / CGFloat(record.image.width), y: value.y / CGFloat(record.image.height))
        }
        return CGPoint(x: min(max(normalized.x, 0), 1), y: min(max(normalized.y, 0), 1))
    }

    func digitizerPoint(_ point: ScreenPoint) -> CGPoint { mapping.digitizerPoint(normalizedPoint(point)) }

    func json(_ point: ScreenPoint) -> JSONValue {
        let normalized = normalizedPoint(point)
        return ["x": .number(normalized.x), "y": .number(normalized.y)]
    }
}
