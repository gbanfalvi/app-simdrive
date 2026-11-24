import CoreGraphics
import SimDriveNative

/// Accessibility frames as fractions of the screenshot, which both follow the interface's rotation, and screenshot
/// fractions as the panel points that hit testing takes.
struct AccessibilityLayout: Equatable, Sendable {
    /// Four decimals place a point within a pixel of the largest screens.
    private static let precision = 10_000.0
    /// In points, so a point on an element's edge still counts as inside it.
    private static let hitTolerance: CGFloat = 1
    /// Elements that show their descendants only within their frame.
    private static let scrollingTypes: Set<ElementType> = [.scrollView, .table, .collectionView, .webView]

    private let interfaceSize: CGSize
    private let panelSize: CGSize
    private let mapping: ScreenMapping
    /// In points: frames start at the app's left edge, which a split app moves.
    private let appOffset: CGFloat

    /// `screenSize` is in points, and turns with the interface on some devices and not on others. `appOrigin` is the
    /// app's left edge as a fraction of the screen's width.
    init(screenSize: CGSize, screenshot: PixelSize, mapping: ScreenMapping, appOrigin: CGFloat = 0) {
        let turned = CGSize(width: screenSize.height, height: screenSize.width)
        interfaceSize = (screenSize.width > screenSize.height) == screenshot.isLandscape ? screenSize : turned
        panelSize = mapping.isRotated ? CGSize(width: interfaceSize.height, height: interfaceSize.width) : interfaceSize
        self.mapping = mapping
        appOffset = appOrigin * interfaceSize.width
    }

    /// `scale` is the screen's pixels per point; without it the app's size stands in for the screen's.
    init(appSize: CGSize, scale: Double?, screen: Screen, appOrigin: CGFloat = 0) {
        self.init(screenSize: Self.screenSize(screenshot: screen.record.full, scale: scale, appSize: appSize),
                  screenshot: screen.record.full, mapping: screen.mapping, appOrigin: appOrigin)
    }

    /// The screen in points, which the app does not span beside the Duo's status strip.
    static func screenSize(screenshot: PixelSize, scale: Double?, appSize: CGSize) -> CGSize {
        guard let scale, scale > 0 else { return appSize }
        return CGSize(width: Double(screenshot.width) / scale, height: Double(screenshot.height) / scale)
    }

    // MARK: Geometry

    /// Whether the widest window spans under `limit` of the screen's width; apps built with older SDKs report the window as
    /// their own frame, so only the screen tells.
    func spansUnder(_ limit: CGFloat, windows: [CGRect]) -> Bool {
        guard let widest = windows.map(\.width).max(), interfaceSize.width > 0 else { return false }
        return widest / interfaceSize.width < limit
    }

    /// Hit testing takes the screen's points, though the element it finds has the app's.
    func panelPoint(_ fraction: CGPoint) -> CGPoint {
        let unit = mapping.digitizerPoint(fraction)
        return CGPoint(x: unit.x * panelSize.width, y: unit.y * panelSize.height)
    }

    /// Whether the element's frame holds a screen fraction. An element without a frame says nothing, so it counts.
    func contains(_ fraction: CGPoint, in element: AccessibilityElement) -> Bool {
        guard !element.frame.isEmpty else { return true }
        let point = CGPoint(x: fraction.x * interfaceSize.width - appOffset, y: fraction.y * interfaceSize.height)
        return element.frame.insetBy(dx: -Self.hitTolerance, dy: -Self.hitTolerance).contains(point)
    }

    /// In the app's points.
    private var screenFrame: CGRect { CGRect(origin: CGPoint(x: -appOffset, y: 0), size: interfaceSize) }

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
        .array(placedElements(root).map(summary))
    }

    /// VoiceOver's elements in hierarchy order, placed on the screen.
    func placedElements(_ root: AccessibilityElement) -> [PlacedElement] {
        var elements: [PlacedElement] = []
        collect(root, visibleFrame: screenFrame, into: &elements)
        return elements
    }

    /// The fields that find and act on an element.
    func summary(_ element: AccessibilityElement) -> JSONValue {
        summary(placed(element, visibleFrame: screenFrame))
    }

    private func collect(_ element: AccessibilityElement, visibleFrame: CGRect, into elements: inout [PlacedElement]) {
        guard !element.isVoiceOverElement else {
            elements.append(placed(element, visibleFrame: visibleFrame))
            return
        }
        let childrenFrame = childrenFrame(of: element, in: visibleFrame)
        for child in element.children {
            collect(child, visibleFrame: childrenFrame, into: &elements)
        }
    }

    private func placed(_ element: AccessibilityElement, visibleFrame: CGRect) -> PlacedElement {
        PlacedElement(element: element, fraction: fraction(point(of: element)), isOffscreen: isOffscreen(element, in: visibleFrame))
    }

    /// Leaves out the value while it repeats the placeholder, as an empty text field's does, and the trait `type` names.
    func summary(_ placed: PlacedElement) -> JSONValue {
        let element = placed.element
        let type = element.type.map { "\($0)" }
        var fields: [String: JSONValue] = ["point": json(fraction: placed.fraction)]
        fields["type"] = type.map(JSONValue.string)
        fields["label"] = element.label.map(JSONValue.string)
        fields["value"] = element.value.flatMap { $0 == element.placeholder ? nil : .string($0) }
        fields["identifier"] = element.identifier.map(JSONValue.string)
        fields["placeholder"] = element.placeholder.map(JSONValue.string)
        fields["traits"] = Self.list(AccessibilityTrait.allCases.filter { element.traits.contains($0) && "\($0)" != type }
            .map { .string("\($0)") })
        fields["offscreen"] = placed.isOffscreen ? true : nil
        fields["focused"] = element.isFocused ? true : nil
        fields["expanded"] = element.isExpanded.map(JSONValue.bool)
        return .object(fields)
    }

    // MARK: Full

    /// Defaults, nil and empty values are left out.
    func json(_ element: AccessibilityElement) -> JSONValue {
        json(element, visibleFrame: screenFrame)
    }

    /// The app's frame stays in the panel's orientation on the Duo's inner panel, overflowing the interface; turned, it fits.
    func json(application: AccessibilityElement) -> JSONValue {
        guard case .object(var fields) = json(application) else { return json(application) }
        let frame = application.frame
        let turned = CGRect(x: frame.minY, y: frame.minX, width: frame.height, height: frame.width)
        let screen = CGRect(origin: .zero, size: interfaceSize).insetBy(dx: -Self.hitTolerance, dy: -Self.hitTolerance)
        if !screen.contains(frame), screen.contains(turned) {
            fields["frame"] = json(turned)
        }
        return .object(fields)
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

    /// An app point as a fraction of the screen, which `tap` takes.
    private func fraction(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x + appOffset) / interfaceSize.width, y: point.y / interfaceSize.height)
    }

    private func json(_ point: CGPoint) -> JSONValue {
        json(fraction: fraction(point))
    }

    private func json(fraction: CGPoint) -> JSONValue {
        ["x": Self.rounded(fraction.x), "y": Self.rounded(fraction.y)]
    }

    private func json(_ frame: CGRect) -> JSONValue {
        ["x": Self.rounded((frame.minX + appOffset) / interfaceSize.width), "y": Self.rounded(frame.minY / interfaceSize.height),
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
