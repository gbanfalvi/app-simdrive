import CoreGraphics
import SimDriveNative

/// The frontmost app's accessibility hierarchy, placed in the screen fractions that `tap` takes.
@MainActor
final class AccessibilityTree {
    private let device: SimulatorDevice
    private let screens: ScreenTargets
    private let accessibility: LazyCapability<SimulatorAccessibility>

    init(device: SimulatorDevice, screens: ScreenTargets) {
        self.device = device
        self.screens = screens
        accessibility = LazyCapability { try await SimulatorAccessibility.open(device: device) }
    }

    func tree() async throws -> JSONValue {
        let accessibility = try await connected()
        let screen = try await screens.screen(.automatic, usesPixels: false)
        let snapshot = try await accessibility.snapshot()
        let layout = AccessibilityLayout(screenSize: snapshot.application.screenSize, screen: screen)
        return ["app": Self.json(snapshot.application), "display": JSONValue(screen.display?.index), "root": layout.json(snapshot.element)]
    }

    /// The element VoiceOver finds at a point, with its descendants.
    func element(at point: ScreenPoint) async throws -> JSONValue {
        let accessibility = try await connected()
        let screen = try await screens.screen(.automatic, usesPixels: point.usesPixels)
        let layout = AccessibilityLayout(screenSize: try await accessibility.application().screenSize, screen: screen)
        let fraction = screen.normalizedPoint(point)
        guard let snapshot = try await accessibility.snapshot(at: layout.panelPoint(fraction), display: screen.display?.index ?? 0) else {
            throw SimDriveError(.noElement, "No accessibility element is at \(fraction.x), \(fraction.y).")
        }
        return ["app": Self.json(snapshot.application), "display": JSONValue(screen.display?.index), "point": screen.json(point),
                "element": layout.json(snapshot.element)]
    }

    /// The frontmost app, or "unsupported".
    func doctorJSON() async throws -> JSONValue {
        guard let accessibility = try await accessibility.value() else { return "unsupported" }
        return Self.json(try await accessibility.application())
    }

    private func connected() async throws -> SimulatorAccessibility {
        guard let accessibility = try await accessibility.value() else {
            throw SimDriveError(.accessibilityUnsupported, "CoreSimulator cannot read \(device.name)'s accessibility.")
        }
        return accessibility
    }

    private static func json(_ application: AccessibilityApplication) -> JSONValue {
        ["name": JSONValue(application.name), "pid": JSONValue(application.pid.map(Int.init))]
    }
}

/// Accessibility frames as fractions of the screenshot, which both follow the interface's rotation, and screenshot
/// fractions as the panel points that hit testing takes.
struct AccessibilityLayout: Equatable, Sendable {
    /// Four decimals place a point within a pixel of the largest screens.
    private static let precision = 10_000.0
    /// Elements that show their descendants only within their frame.
    private static let scrollingTypes: Set<ElementType> = [.scrollView, .table, .collectionView, .webView]

    private let interfaceSize: CGSize
    private let panelSize: CGSize
    private let mapping: ScreenMapping

    /// `screenSize` is the app's size in points, which turns with the interface on some devices and not on others.
    init(screenSize: CGSize, screenshot: PixelSize, mapping: ScreenMapping) {
        let turned = CGSize(width: screenSize.height, height: screenSize.width)
        interfaceSize = (screenSize.width > screenSize.height) == screenshot.isLandscape ? screenSize : turned
        panelSize = mapping.isRotated ? CGSize(width: interfaceSize.height, height: interfaceSize.width) : interfaceSize
        self.mapping = mapping
    }

    init(screenSize: CGSize, screen: ScreenTargets.Target) {
        self.init(screenSize: screenSize, screenshot: screen.record.full, mapping: screen.mapping)
    }

    func panelPoint(_ fraction: CGPoint) -> CGPoint {
        let unit = mapping.digitizerPoint(fraction)
        return CGPoint(x: unit.x * panelSize.width, y: unit.y * panelSize.height)
    }

    /// Defaults, nil and empty values are left out.
    func json(_ element: AccessibilityElement) -> JSONValue {
        json(element, visibleFrame: CGRect(origin: .zero, size: interfaceSize))
    }

    /// `visibleFrame` is the part of the screen that the element's scrolling ancestors show.
    private func json(_ element: AccessibilityElement, visibleFrame: CGRect) -> JSONValue {
        var fields: [String: JSONValue] = ["frame": json(element.frame), "point": json(element.activationPoint ?? element.frame.center)]
        fields["type"] = element.type.map { .string("\($0)") }
        fields["label"] = element.label.map(JSONValue.string)
        fields["value"] = element.value.map(JSONValue.string)
        fields["hint"] = element.hint.map(JSONValue.string)
        fields["identifier"] = element.identifier.map(JSONValue.string)
        fields["placeholder"] = element.placeholder.map(JSONValue.string)
        fields["traits"] = Self.list(AccessibilityTrait.allCases.filter(element.traits.contains).map { .string("\($0)") })
        fields["voiceOver"] = element.isVoiceOverElement ? true : nil
        fields["offscreen"] = element.isVoiceOverElement && !visibleFrame.intersects(element.frame) ? true : nil
        fields["focused"] = element.isFocused ? true : nil
        fields["expanded"] = element.isExpanded.map(JSONValue.bool)
        fields["headingLevel"] = element.headingLevel.map { .number(Double($0)) }
        fields["containerType"] = element.containerType.map { .string("\($0)") }
        fields["language"] = element.language.map(JSONValue.string)
        fields["inputLabels"] = Self.list(element.inputLabels.map(JSONValue.string))
        fields["customActions"] = Self.list(element.customActions.map(JSONValue.string))
        fields["customContent"] = Self.list(element.customContent.map { content in
            var item: [String: JSONValue] = ["label": .string(content.label), "value": .string(content.value)]
            item["important"] = content.isImportant ? true : nil
            return .object(item)
        })
        fields["url"] = element.url.map(JSONValue.string)
        fields["range"] = element.range.map { range in
            var item: [String: JSONValue] = ["min": .number(range.minimum), "max": .number(range.maximum)]
            item["value"] = range.value.map(JSONValue.number)
            return .object(item)
        }
        fields["class"] = element.className.map(JSONValue.string)
        fields["viewController"] = element.viewController.map(JSONValue.string)
        let childrenFrame = element.type.map(Self.scrollingTypes.contains) == true ? visibleFrame.intersection(element.frame) : visibleFrame
        fields["children"] = Self.list(element.children.map { json($0, visibleFrame: childrenFrame) })
        return .object(fields)
    }

    private func json(_ point: CGPoint) -> JSONValue {
        ["x": Self.rounded(point.x / interfaceSize.width), "y": Self.rounded(point.y / interfaceSize.height)]
    }

    private func json(_ frame: CGRect) -> JSONValue {
        ["x": Self.rounded(frame.minX / interfaceSize.width), "y": Self.rounded(frame.minY / interfaceSize.height),
         "width": Self.rounded(frame.width / interfaceSize.width), "height": Self.rounded(frame.height / interfaceSize.height)]
    }

    private static func rounded(_ value: CGFloat) -> JSONValue {
        .number((value * precision).rounded() / precision)
    }

    private static func list(_ values: [JSONValue]) -> JSONValue? {
        values.isEmpty ? nil : .array(values)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
