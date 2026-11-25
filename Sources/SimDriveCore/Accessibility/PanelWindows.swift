import CoreGraphics
import SimDriveNative

/// SpringBoard's windows on a device with two panels, as an iPhone Duo. Its tree holds both panels' windows, each at
/// the origin: the other panel's, in its points and pixels, which give duplicates at wrong places, and this panel's
/// copies in its native, unturned coordinates when the panel is quarter-turned (iOS 27.2, I12). Apps are unaffected.
enum PanelWindows {
    /// In points, so a window measured in another panel's size still matches.
    private static let tolerance: CGFloat = 1

    /// The tree with the other panel's windows and every pixel-sized one dropped, and this panel's native-coordinate
    /// windows turned into the interface's. `interfaceSize` is the screen in points as the interface draws it,
    /// `otherPanels` the other panels' native sizes in points, `scale` pixels per point.
    static func normalize(_ root: AccessibilityElement, interfaceSize: CGSize, otherPanels: [CGSize], scale: CGFloat,
                          mapping: ScreenMapping, screenID: Int? = nil) -> AccessibilityElement {
        guard !otherPanels.isEmpty else { return root }
        let root = screenID.map { onDisplay(root, $0) } ?? root
        let turned = CGSize(width: interfaceSize.height, height: interfaceSize.width)
        let dropped = otherPanels.flatMap { [$0, scaled($0, scale)] } + [scaled(interfaceSize, scale)]
        let windows = root.children.compactMap { window -> AccessibilityElement? in
            guard window.frame.origin == .zero else { return window }
            let size = window.frame.size
            if dropped.contains(where: { matches(size, $0) }) { return nil }
            guard mapping.isRotated, isSame(size, turned) else { return window }
            return fromNative(window, interfaceSize: interfaceSize, mapping: mapping)
        }
        return root.with(children: windows)
    }

    /// An element of one of this panel's native-coordinate windows, and its descendants, in the interface's points.
    static func fromNative(_ element: AccessibilityElement, interfaceSize: CGSize, mapping: ScreenMapping) -> AccessibilityElement {
        element.converting { nativePoint($0, interfaceSize: interfaceSize, mapping: mapping) }
    }

    /// The element a hit test found, placed in the interface, or nil when it is not on this panel. A hit test has no
    /// window to tell native coordinates by, so an element counts as native when only its turned frame holds the point
    /// tested (F35). `holds` says whether a placed element's frame holds that point.
    static func hitElement(_ element: AccessibilityElement, interfaceSize: CGSize, mapping: ScreenMapping, screenID: Int?,
                           holds: (AccessibilityElement) -> Bool) -> AccessibilityElement? {
        if let screenID, let display = element.displayID, display != screenID { return nil }
        if holds(element) { return element }
        guard mapping.isRotated else { return nil }
        let turned = fromNative(element, interfaceSize: interfaceSize, mapping: mapping)
        return holds(turned) ? turned : nil
    }

    /// The tree without the elements that report another display. Within this panel's own windows, SpringBoard lists
    /// some icons with the other panel's frames, and each reports that panel's display (attribute 2123, I12).
    static func onDisplay(_ element: AccessibilityElement, _ screenID: Int) -> AccessibilityElement {
        element.with(children: element.children.compactMap { child in
            if let display = child.displayID, display != screenID { return nil }
            return onDisplay(child, screenID)
        })
    }

    /// A point read in the panel's native coordinates, whose width is the interface's height, in the interface's.
    static func nativePoint(_ point: CGPoint, interfaceSize: CGSize, mapping: ScreenMapping) -> CGPoint {
        let unit = CGPoint(x: point.x / interfaceSize.height, y: point.y / interfaceSize.width)
        let screenshot = mapping.screenshotPoint(fromDigitizer: unit)
        return CGPoint(x: screenshot.x * interfaceSize.width, y: screenshot.y * interfaceSize.height)
    }

    /// Equal in either orientation.
    private static func matches(_ size: CGSize, _ other: CGSize) -> Bool {
        isSame(size, other) || isSame(size, CGSize(width: other.height, height: other.width))
    }

    private static func isSame(_ size: CGSize, _ other: CGSize) -> Bool {
        abs(size.width - other.width) <= tolerance && abs(size.height - other.height) <= tolerance
    }

    private static func scaled(_ size: CGSize, _ scale: CGFloat) -> CGSize {
        CGSize(width: size.width * scale, height: size.height * scale)
    }
}
