import CoreGraphics
import SimDriveNative

/// The frontmost app's accessibility hierarchy, placed in the screen fractions that `tap` takes.
@MainActor
final class DeviceAccessibility {
    private let device: SimulatorDevice
    private let screens: Screens
    private let accessibility: LazyCapability<SimulatorAccessibility>

    init(device: SimulatorDevice, screens: Screens) {
        self.device = device
        self.screens = screens
        accessibility = LazyCapability { try await SimulatorAccessibility.open(device: device) }
    }

    func tree(detail: TreeDetail) async throws -> JSONValue {
        let accessibility = try await connected()
        let screen = try await screens.screen(.automatic, usesPixels: false)
        let snapshot = try await accessibility.snapshot(detail: detail)
        let layout = AccessibilityLayout(screenSize: snapshot.application.screenSize, screen: screen)
        let app = snapshot.application.json
        let display = JSONValue(screen.display?.index)
        switch detail {
        case .light: return ["app": app, "display": display, "elements": layout.elements(snapshot.element)]
        case .full: return ["app": app, "display": display, "root": layout.json(snapshot.element)]
        }
    }

    /// The element VoiceOver finds at a point, with its descendants when full.
    func element(at point: ScreenPoint, detail: TreeDetail) async throws -> JSONValue {
        let accessibility = try await connected()
        let screen = try await screens.screen(.automatic, usesPixels: point.usesPixels)
        let fraction = screen.normalizedPoint(point)
        let panelPoint: @Sendable (CGSize) -> CGPoint = { AccessibilityLayout(screenSize: $0, screen: screen).panelPoint(fraction) }
        guard let snapshot = try await accessibility.snapshot(at: panelPoint, display: screen.display?.index ?? 0, detail: detail) else {
            throw SimDriveError(.noElement, "No accessibility element is at \(fraction.x), \(fraction.y).")
        }
        let layout = AccessibilityLayout(screenSize: snapshot.application.screenSize, screen: screen)
        let element = switch detail {
        case .light: layout.summary(snapshot.element)
        case .full: layout.json(snapshot.element)
        }
        return ["app": snapshot.application.json, "display": JSONValue(screen.display?.index), "point": screen.json(point),
                "element": element]
    }

    /// The frontmost app, or "unsupported".
    func doctorJSON() async throws -> JSONValue {
        guard let accessibility = try await accessibility.value() else { return .unsupported }
        return try await accessibility.application().json
    }

    private func connected() async throws -> SimulatorAccessibility {
        try await accessibility.required(orThrow: SimDriveError(.accessibilityUnsupported,
                                                                "CoreSimulator cannot read \(device.name)'s accessibility."))
    }
}
