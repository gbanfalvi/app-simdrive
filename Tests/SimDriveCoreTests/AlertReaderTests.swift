import CoreGraphics
@testable import SimDriveNative
import Testing
@testable import SimDriveCore

/// Trees shaped like those read on an iPhone 17, iOS 27.2.
struct AlertReaderTests {
    private static func node(_ className: String?, label: String? = nil, traits: Set<AccessibilityTrait> = [],
                             identifier: String? = nil, voiceOver: Bool = false, _ children: [AccessibilityElement] = []) -> AccessibilityElement {
        var element = AccessibilityElement()
        element.className = className
        element.label = label
        element.traits = traits
        element.identifier = identifier
        element.isVoiceOverElement = voiceOver
        element.children = children
        return element
    }

    private static func button(_ label: String, identifier: String? = nil) -> AccessibilityElement {
        node("_UIInterfaceActionCustomViewRepresentationView", label: label, traits: [.button], identifier: identifier, voiceOver: true,
             [node("_UIAlertControllerActionView", label: label, traits: [.button])])
    }

    private static func text(_ label: String) -> AccessibilityElement {
        node("UILabel", label: label, traits: [.staticText], voiceOver: true)
    }

    /// SpringBoard's photo-permission alert.
    private static let permission = node("UIApplication", [
        node("STUIStatusBarStringView", label: "16:31", traits: [.staticText], voiceOver: true),
        node("_UIAlertControllerPhoneTVMacView", label: "Allow “AXProbe” to access your photo library?", [
            node("_UIAlertControllerInterfaceActionGroupView", [
                text("Allow “AXProbe” to access your photo library?"), text("The evaluation matrix checks photo access."),
                button("Select Photos", identifier: "kTCCServicePhotos-limited-button"),
                button("Allow Full Access", identifier: "kTCCServicePhotos-allow-button"),
                button("Don’t Allow", identifier: "kTCCServicePhotos-deny-button"),
            ]),
        ]),
    ])

    /// The probe's own alert over its screen.
    private static let appAlert = node("UIApplication", [node("UIWindow", [
        node("UITransitionView", [button("Play")]),
        node("UITransitionView", [node("_UIAlertControllerPhoneTVMacView", label: "Probe alert", [
            text("Probe alert"), text("Covers the probe"), button("Dismiss"), button("Confirm"),
        ])]),
    ])])

    @Test func readsTitleMessageAndButtonsNotTheStatusBar() throws {
        let alert = try #require(AlertReader.alert(in: Self.permission))
        #expect(alert.title == "Allow “AXProbe” to access your photo library?")
        #expect(alert.message == "The evaluation matrix checks photo access.")
        #expect(alert.buttons.map(\.label) == ["Select Photos", "Allow Full Access", "Don’t Allow"])
    }

    @Test func noAlertInAnOrdinaryTree() {
        #expect(AlertReader.alert(in: Self.node("UIApplication", [Self.button("Play")])) == nil)
    }

    @Test func permissionButtonsAnswerByIdentifier() throws {
        let buttons = try #require(AlertReader.alert(in: Self.permission)).buttons
        #expect(AlertReader.button(for: .accept, in: buttons)?.label == "Allow Full Access")
        #expect(AlertReader.button(for: .dismiss, in: buttons)?.label == "Don’t Allow")
    }

    /// Accepting unknown labels takes UIKit's default action, the last button.
    @Test func otherAlertsAnswerByLabelThenTheDefaultAction() throws {
        let buttons = try #require(AlertReader.alert(in: Self.appAlert)).buttons
        #expect(AlertReader.button(for: .accept, in: buttons)?.label == "Confirm")
        #expect(AlertReader.button(for: .dismiss, in: buttons)?.label == "Dismiss")
        #expect(AlertReader.button(for: .accept, in: [Self.button("Keep"), Self.button("Replace")])?.label == "Replace")
        #expect(AlertReader.button(for: .dismiss, in: [Self.button("OK")])?.label == "OK")
    }

    /// German labels, which the lists lack: dismissing by position could grant the permission.
    @Test func dismissNeverGuessesAmongUnknownLabels() {
        #expect(AlertReader.button(for: .dismiss, in: [Self.button("Erlauben"), Self.button("Nicht erlauben")]) == nil)
    }
}
