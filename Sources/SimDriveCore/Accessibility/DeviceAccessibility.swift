import CoreGraphics
import SimDriveNative

/// The frontmost app's accessibility hierarchy, placed in the screen fractions that `tap` takes.
@MainActor
final class DeviceAccessibility {
    private static let frontmostPollInterval: Duration = .milliseconds(100)
    /// A split app's window is about 0.49 of the screen wide, and a full one 1.
    private static let halfWidthLimit = 0.75

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
        let fillsHalf = Self.fillsHalf(snapshot.element.children.map(\.frame), of: snapshot.application)
        let layout = AccessibilityLayout(appSize: snapshot.application.screenSize, scale: device.screenScale, screen: screen,
                                         appOrigin: appOrigin(fillsHalf: fillsHalf))
        let app = snapshot.application.json
        let display = JSONValue(screen.display?.index)
        switch detail {
        case .light: return ["app": app, "display": display, "elements": layout.elements(snapshot.element)]
        case .full: return ["app": app, "display": display, "root": layout.json(application: snapshot.element)]
        }
    }

    /// The element VoiceOver finds at a point, with its descendants when full.
    func element(at point: ScreenPoint, detail: TreeDetail) async throws -> JSONValue {
        let accessibility = try await connected()
        let screen = try await screens.screen(.automatic, usesPixels: point.usesPixels)
        let fraction = screen.normalizedPoint(point)
        let scale = device.screenScale
        let panelPoint: @Sendable (CGSize) -> CGPoint = {
            AccessibilityLayout(appSize: $0, scale: scale, screen: screen).panelPoint(fraction)
        }
        let noElement = SimDriveError(.noElement, "No accessibility element is at \(fraction.x), \(fraction.y).")
        guard let snapshot = try await accessibility.snapshot(at: panelPoint, display: screen.display?.index ?? 0, detail: detail) else {
            throw noElement
        }
        let origin = screens.splitLayout?.isHalf == true ? appOrigin(fillsHalf: try await fillsHalf()) : 0
        let layout = AccessibilityLayout(appSize: snapshot.application.screenSize, scale: scale, screen: screen, appOrigin: origin)
        // Web content can answer with an element away from the point.
        guard layout.contains(fraction, in: snapshot.element) else { throw noElement }
        let element = switch detail {
        case .light: layout.summary(snapshot.element)
        case .full: layout.json(snapshot.element)
        }
        return ["app": snapshot.application.json, "display": JSONValue(screen.display?.index), "point": screen.json(point),
                "element": element]
    }

    /// Whether the frontmost app's windows fill one half of a split screen.
    func fillsHalf() async throws -> Bool {
        let (application, frames) = try await connected().windows()
        return Self.fillsHalf(frames, of: application)
    }

    private static func fillsHalf(_ windows: [CGRect], of application: AccessibilityApplication) -> Bool {
        guard let widest = windows.map(\.width).max(), application.screenSize.width > 0 else { return false }
        return widest / application.screenSize.width < halfWidthLimit
    }

    /// Only the half simdrive last set says which half a split app fills.
    private func appOrigin(fillsHalf: Bool) -> CGFloat {
        guard fillsHalf, let layout = screens.splitLayout, layout.isHalf else { return 0 }
        return layout.appOrigin
    }

    /// Whether the app of `pid` comes to the front within `limit`; true when accessibility cannot tell.
    func becomesFrontmost(_ pid: Int, within limit: Duration) async -> Bool {
        guard let accessibility = try? await accessibility.value() else { return true }
        let deadline = ContinuousClock.now + limit
        repeat {
            // A launching app answers with nothing at first.
            if let application = try? await accessibility.application() {
                guard let frontmost = application.pid else { return true }
                if Int(frontmost) == pid { return true }
            }
            try? await Task.sleep(for: Self.frontmostPollInterval)
        } while ContinuousClock.now < deadline
        return false
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
