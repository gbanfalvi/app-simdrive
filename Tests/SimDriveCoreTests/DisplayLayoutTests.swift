import CoreGraphics
import Testing
@testable import SimDriveCore

struct DisplayLayoutTests {
    private static let app = "<SBSDisplayLayoutElement: 0x1; sceneID:com.simdrive.axprobe-default; bundleID: com.simdrive.axprobe; "
    private static let dock = "<SBSDisplayLayoutElement: 0x2; com.apple.springboard.floating-dock; frame: {{867, 0}, {84, 669}}; level: -1; role: overlay>;"
    private static let switcher = "<SBSDisplayLayoutElement: 0x3; com.apple.springboard.app-switcher; frame: {{0, 0}, {951, 669}}; level: 1; role: primary>;"

    private static func message(_ elements: String...) -> String {
        """
        _updateLayout <FBSDisplayLayout: 0x4; displayIdentity: Unknown.main[3]> {
            bounds = {{0, 0}, {951, 669}};
            referenceBounds = {{0, 0}, {669, 951}};
            elements = {
                \(elements.joined(separator: "\n        "))
            }
        } reason: SBSceneLayoutWorkspaceTransaction
        """
    }

    private static func app(_ frame: String) -> String { app + "frame: \(frame); level: 1; hasKeyboardFocus; role: primary>;" }

    @Test func decodesBoundsAndElements() throws {
        let layout = try #require(DisplayLayout(message: Self.message(Self.dock, Self.app("{{482, 0}, {469, 669}}"))))
        #expect(layout.bounds == CGRect(x: 0, y: 0, width: 951, height: 669))
        #expect(layout.elements == [
            .init(bundleID: nil, frame: CGRect(x: 867, y: 0, width: 84, height: 669), role: "overlay"),
            .init(bundleID: "com.simdrive.axprobe", frame: CGRect(x: 482, y: 0, width: 469, height: 669), role: "primary"),
        ])
    }

    @Test func tellsTheHalfFromTheAppsFrame() {
        let frames: [(String, SplitLayout)] = [
            ("{{0, 0}, {951, 669}}", .full), ("{{0, 0}, {469, 669}}", .left), ("{{482, 0}, {469, 669}}", .right),
            ("{{0, 0}, {475.66666666666669, 669}}", .left),
        ]
        for (frame, layout) in frames {
            #expect(DisplayLayout(message: Self.message(Self.dock, Self.app(frame)))?.splitLayout == layout)
        }
    }

    @Test func theAppSwitcherIsNoSplit() {
        #expect(DisplayLayout(message: Self.message(Self.switcher, Self.app("{{0, 0}, {951, 669}}")))?.splitLayout == nil)
    }

    @Test func ignoresOtherMessages() {
        #expect(DisplayLayout(message: "Executing request: <SBMainWorkspaceTransitionRequest>") == nil)
    }
}
