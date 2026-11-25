import CoreGraphics
@testable import SimDriveNative
import Testing
@testable import SimDriveCore

/// Windows and points as an iPhone Duo's SpringBoard reported them on iOS 27.2: the cover panel is 466 × 678 points,
/// the inner one 669 × 951, at 3 pixels per point.
struct PanelWindowsTests {
    private static let cover = CGSize(width: 466, height: 678)
    private static let inner = CGSize(width: 669, height: 951)
    /// Open: the inner panel, turned to landscape.
    private static let open = CGSize(width: 951, height: 669)
    private static let openMapping = ScreenMapping(isRotated: true, orientation: .portrait)

    private static func window(_ size: CGSize, _ labels: [(String, CGPoint)]) -> AccessibilityElement {
        var window = AccessibilityElement()
        window.frame = CGRect(origin: .zero, size: size)
        window.children = labels.map { label, point in
            var element = AccessibilityElement()
            element.label = label
            element.isVoiceOverElement = true
            element.frame = CGRect(x: point.x - 20, y: point.y - 20, width: 40, height: 40)
            return element
        }
        return window
    }

    private static func root(_ windows: [AccessibilityElement]) -> AccessibilityElement {
        var root = AccessibilityElement()
        root.children = windows
        return root
    }

    /// Closed: the cover panel's own windows stay; the inner panel's, in points and pixels, go.
    @Test func closedDropsTheInnerPanelsWindows() {
        let tree = Self.root([
            Self.window(Self.cover, [("Calendar", CGPoint(x: 57, y: 282))]),
            Self.window(Self.open, [("Safari", CGPoint(x: 348, y: 48))]),
            Self.window(CGSize(width: 2007, height: 2853), [("Ghost", CGPoint(x: 2300, y: -292))]),
            Self.window(CGSize(width: 1398, height: 2034), []),
        ])
        let kept = PanelWindows.normalize(tree, interfaceSize: Self.cover, otherPanels: [Self.inner], scale: 3,
                                          mapping: ScreenMapping(isRotated: false, orientation: .portrait))
        #expect(kept.children.map { $0.children.map(\.label) } == [["Calendar"]])
    }

    /// Open: the cover panel's windows go, and the inner panel's native-coordinate dock turns into the interface's:
    /// Safari read at (0.3656, 0.0715) of the interface is drawn at (0.95, 0.52).
    @Test func openTurnsNativeWindowsAndDropsTheCoversWindows() throws {
        let tree = Self.root([
            Self.window(Self.cover, [("Calendar", CGPoint(x: 57, y: 282))]),
            Self.window(Self.inner, [("Safari", CGPoint(x: 0.3656 * 951, y: 0.0715 * 669))]),
        ])
        let kept = PanelWindows.normalize(tree, interfaceSize: Self.open, otherPanels: [Self.cover], scale: 3, mapping: Self.openMapping)
        let safari = try #require(kept.children.first?.children.first)
        #expect(kept.children.count == 1)
        #expect(abs(safari.frame.midX / 951 - 0.95) < 0.005)
        #expect(abs(safari.frame.midY / 669 - 0.52) < 0.005)
    }

    /// A single-panel device has nothing to drop.
    @Test func onePanelChangesNothing() {
        let tree = Self.root([Self.window(CGSize(width: 1206, height: 2622), [("Play", CGPoint(x: 10, y: 10))])])
        #expect(PanelWindows.normalize(tree, interfaceSize: CGSize(width: 402, height: 874), otherPanels: [], scale: 3,
                                       mapping: ScreenMapping(isRotated: false, orientation: .portrait)) == tree)
    }

    @Test func screenshotPointUndoesDigitizerPoint() {
        for mapping in [Self.openMapping, ScreenMapping(isRotated: true, orientation: .landscapeLeft),
                        ScreenMapping(isRotated: false, orientation: .portraitUpsideDown)] {
            let point = CGPoint(x: 0.2, y: 0.7)
            let back = mapping.screenshotPoint(fromDigitizer: mapping.digitizerPoint(point))
            #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
        }
    }
}
