import CoreGraphics
import SimDriveNative

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

    init(screenSize: CGSize, screen: Screen) {
        self.init(screenSize: screenSize, screenshot: screen.record.full, mapping: screen.mapping)
    }

    // MARK: Geometry

    func panelPoint(_ fraction: CGPoint) -> CGPoint {
        let unit = mapping.digitizerPoint(fraction)
        return CGPoint(x: unit.x * panelSize.width, y: unit.y * panelSize.height)
    }

    private var screenFrame: CGRect { CGRect(origin: .zero, size: interfaceSize) }

    private func point(of element: AccessibilityElement) -> CGPoint {
        element.activationPoint ?? element.frame.center
    }

    private func isOffscreen(_ element: AccessibilityElement, in visibleFrame: CGRect) -> Bool {
        element.isVoiceOverElement && !visibleFrame.intersects(element.frame)
    }

    private func childrenFrame(of element: AccessibilityElement, in visibleFrame: CGRect) -> CGRect {
        element.type.map(Self.scrollingTypes.contains) == true ? visibleFrame.intersection(element.frame) : visibleFrame
    }

    // MARK: Light

    /// VoiceOver's elements in hierarchy order, as `summary` describes them.
    func elements(_ root: AccessibilityElement) -> JSONValue {
        var elements: [JSONValue] = []
        collect(root, visibleFrame: screenFrame, into: &elements)
        return .array(elements)
    }

    /// The fields that find and act on an element.
    func summary(_ element: AccessibilityElement) -> JSONValue {
        summary(element, visibleFrame: screenFrame)
    }

    private func collect(_ element: AccessibilityElement, visibleFrame: CGRect, into elements: inout [JSONValue]) {
        guard !element.isVoiceOverElement else {
            elements.append(summary(element, visibleFrame: visibleFrame))
            return
        }
        let childrenFrame = childrenFrame(of: element, in: visibleFrame)
        for child in element.children {
            collect(child, visibleFrame: childrenFrame, into: &elements)
        }
    }

    /// Leaves out the value while it repeats the placeholder, as an empty text field's does, and the trait `type` names.
    private func summary(_ element: AccessibilityElement, visibleFrame: CGRect) -> JSONValue {
        let type = element.type.map { "\($0)" }
        var fields: [String: JSONValue] = ["point": json(point(of: element))]
        fields["type"] = type.map(JSONValue.string)
        fields["label"] = element.label.map(JSONValue.string)
        fields["value"] = element.value.flatMap { $0 == element.placeholder ? nil : .string($0) }
        fields["identifier"] = element.identifier.map(JSONValue.string)
        fields["placeholder"] = element.placeholder.map(JSONValue.string)
        fields["traits"] = Self.list(AccessibilityTrait.allCases.filter { element.traits.contains($0) && "\($0)" != type }
            .map { .string("\($0)") })
        fields["offscreen"] = isOffscreen(element, in: visibleFrame) ? true : nil
        fields["focused"] = element.isFocused ? true : nil
        fields["expanded"] = element.isExpanded.map(JSONValue.bool)
        return .object(fields)
    }

    // MARK: Full

    /// Defaults, nil and empty values are left out.
    func json(_ element: AccessibilityElement) -> JSONValue {
        json(element, visibleFrame: screenFrame)
    }

    /// `visibleFrame` is the part of the screen that the element's scrolling ancestors show.
    private func json(_ element: AccessibilityElement, visibleFrame: CGRect) -> JSONValue {
        var fields: [String: JSONValue] = ["frame": json(element.frame), "point": json(point(of: element))]
        fields["type"] = element.type.map { .string("\($0)") }
        fields["label"] = element.label.map(JSONValue.string)
        fields["value"] = element.value.map(JSONValue.string)
        fields["hint"] = element.hint.map(JSONValue.string)
        fields["identifier"] = element.identifier.map(JSONValue.string)
        fields["placeholder"] = element.placeholder.map(JSONValue.string)
        fields["traits"] = Self.list(AccessibilityTrait.allCases.filter(element.traits.contains).map { .string("\($0)") })
        fields["voiceOver"] = element.isVoiceOverElement ? true : nil
        fields["offscreen"] = isOffscreen(element, in: visibleFrame) ? true : nil
        fields["focused"] = element.isFocused ? true : nil
        fields["expanded"] = element.isExpanded.map(JSONValue.bool)
        fields["headingLevel"] = element.headingLevel.map { JSONValue($0) }
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
        let childrenFrame = childrenFrame(of: element, in: visibleFrame)
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
