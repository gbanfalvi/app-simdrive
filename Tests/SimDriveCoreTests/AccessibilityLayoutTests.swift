import CoreGraphics
@testable import SimDriveNative
import Testing
@testable import SimDriveCore

struct AccessibilityLayoutTests {
    private let phone = Self.layout(screen: CGSize(width: 402, height: 874), screenshot: PixelSize(width: 1206, height: 2622))
    /// A turned phone reports its interface's size.
    private let landscapePhone = Self.layout(screen: CGSize(width: 874, height: 402), screenshot: PixelSize(width: 2622, height: 1206),
                                             mapping: ScreenMapping(isRotated: true, orientation: .landscapeLeft))
    /// The Duo's inner panel is portrait natively and reports its panel's size; its interface and screenshots are landscape.
    private let duoInner = Self.layout(screen: CGSize(width: 669, height: 951), screenshot: PixelSize(width: 1902, height: 1338),
                                       mapping: ScreenMapping(isRotated: true, orientation: .portrait))
    private let television = Self.layout(screen: CGSize(width: 1920, height: 1080), screenshot: PixelSize(width: 1920, height: 1080))

    @Test func fractionsBecomePanelPoints() {
        #expect(phone.panelPoint(CGPoint(x: 0.5, y: 0.25)) == CGPoint(x: 201, y: 218.5))
        #expect(landscapePhone.panelPoint(CGPoint(x: 0.5, y: 0.25)) == CGPoint(x: 301.5, y: 437))
        #expect(duoInner.panelPoint(CGPoint(x: 0.25, y: 0.5)) == CGPoint(x: 334.5, y: 713.25))
        #expect(television.panelPoint(CGPoint(x: 0.25, y: 0.5)) == CGPoint(x: 480, y: 540))
    }

    @Test func framesFollowTheInterfaceWhicheverWayTheAppReportsItsSize() {
        var button = AccessibilityElement()
        button.frame = CGRect(x: 78, y: 72.66, width: 718, height: 30)
        #expect(landscapePhone.json(button) == ["frame": ["x": 0.0892, "y": 0.1807, "width": 0.8215, "height": 0.0746],
                                                "point": ["x": 0.5, "y": 0.2181]])
    }

    @Test func turnedScreensMeasureFramesAlongTheInterface() {
        var row = AccessibilityElement()
        row.frame = CGRect(x: 0, y: 0, width: 951, height: 66.9)
        row.activationPoint = CGPoint(x: 603.5, y: 329.7)
        let json = duoInner.json(row)
        #expect(json == ["frame": ["x": 0, "y": 0, "width": 1, "height": 0.1], "point": ["x": 0.6346, "y": 0.4928]])
    }

    @Test func pointsDefaultToTheFrameCenter() {
        var element = AccessibilityElement()
        element.frame = CGRect(x: 100.5, y: 437, width: 201, height: 87.4)
        #expect(phone.json(element) == ["frame": ["x": 0.25, "y": 0.5, "width": 0.5, "height": 0.1], "point": ["x": 0.5, "y": 0.55]])
    }

    @Test func namesTypesTraitsAndContent() {
        var element = AccessibilityElement()
        element.type = .switch
        element.label = "Wi-Fi"
        element.traits = [.toggleButton, .button, .selected]
        element.isVoiceOverElement = true
        element.isExpanded = false
        element.containerType = .semanticGroup
        element.customContent = [AccessibilityCustomContent(label: "Age", value: "3 years", isImportant: false),
                                 AccessibilityCustomContent(label: "Breed", value: "Corgi", isImportant: true)]
        guard case .object(let json) = phone.json(element) else {
            Issue.record("An element is an object")
            return
        }
        #expect(json["type"] == "switch")
        #expect(json["traits"] == ["button", "selected", "toggleButton"])
        #expect(json["voiceOver"] == true)
        #expect(json["expanded"] == false)
        #expect(json["containerType"] == "semanticGroup")
        #expect(json["customContent"] == [["label": "Age", "value": "3 years"], ["label": "Breed", "value": "Corgi", "important": true]])
        #expect(json["offscreen"] == nil)
        #expect(json["children"] == nil)
    }

    @Test func voiceOverElementsOutsideTheScreenOrTheirScrollViewAreOffscreen() {
        func row(_ label: String, y: CGFloat, isVoiceOverElement: Bool = true) -> AccessibilityElement {
            var row = AccessibilityElement()
            row.label = label
            row.frame = CGRect(x: 0, y: y, width: 402, height: 44)
            row.isVoiceOverElement = isVoiceOverElement
            return row
        }
        var list = AccessibilityElement()
        list.type = .table
        list.frame = CGRect(x: 0, y: 100, width: 402, height: 400)
        list.children = [row("Shown", y: 480), row("Scrolled", y: 600), row("Container", y: 600, isVoiceOverElement: false)]
        var root = AccessibilityElement()
        root.children = [list, row("Below", y: 900), row("Visible", y: 600)]
        #expect(Self.offscreenLabels(phone.json(root)) == ["Scrolled", "Below"])
    }

    @Test func childrenNest() {
        var child = AccessibilityElement()
        child.label = "Play"
        var parent = AccessibilityElement()
        parent.children = [child]
        guard case .object(let json) = phone.json(parent), case .array(let children) = json["children"],
              case .object(let first) = children.first else {
            Issue.record("Children are an array of objects")
            return
        }
        #expect(first["label"] == "Play")
    }

    @Test func lightTreesListVoiceOverElementsFlat() {
        var title = AccessibilityElement()
        title.label = "Title"
        var cell = AccessibilityElement()
        cell.type = .cell
        cell.label = "Row"
        cell.isVoiceOverElement = true
        cell.frame = CGRect(x: 0, y: 600, width: 402, height: 44)
        cell.children = [title]
        var list = AccessibilityElement()
        list.type = .table
        list.frame = CGRect(x: 0, y: 100, width: 402, height: 400)
        list.children = [cell]
        var play = AccessibilityElement()
        play.label = "Play"
        play.isVoiceOverElement = true
        play.frame = CGRect(x: 100.5, y: 437, width: 201, height: 87.4)
        var root = AccessibilityElement()
        root.children = [list, play]
        #expect(phone.elements(root) == [["type": "cell", "label": "Row", "point": ["x": 0.5, "y": 0.7117], "offscreen": true],
                                         ["label": "Play", "point": ["x": 0.5, "y": 0.55]]])
    }

    @Test func lightElementsLeaveOutWhatTheirTypeOrPlaceholderRepeat() {
        var field = AccessibilityElement()
        field.type = .textField
        field.value = "Email"
        field.placeholder = "Email"
        var button = AccessibilityElement()
        button.type = .button
        button.traits = [.button, .selected]
        button.hint = "Plays the song"
        button.className = "UIButton"
        #expect(phone.summary(field) == ["type": "textField", "placeholder": "Email", "point": ["x": 0, "y": 0]])
        #expect(phone.summary(button) == ["type": "button", "traits": ["selected"], "point": ["x": 0, "y": 0]])
    }

    private static func offscreenLabels(_ json: JSONValue) -> [String] {
        guard case .object(let fields) = json else { return [] }
        let children: [String] = if case .array(let children)? = fields["children"] { children.flatMap(offscreenLabels) } else { [] }
        guard fields["offscreen"] == true, case .string(let label)? = fields["label"] else { return children }
        return [label] + children
    }

    private static func layout(screen: CGSize, screenshot: PixelSize,
                               mapping: ScreenMapping = ScreenMapping(isRotated: false, orientation: .portrait)) -> AccessibilityLayout {
        AccessibilityLayout(screenSize: screen, screenshot: screenshot, mapping: mapping)
    }
}
