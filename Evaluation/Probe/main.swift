import Accessibility
import AVFoundation
import SwiftUI
import UIKit

enum Log {
    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("probe.log")

    static func write(_ line: String) {
        let stamped = "\(Date().timeIntervalSince1970) \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
    }

    static func statusLine(traits: UITraitCollection) -> String {
        let values: [(String, Bool)] = [
            ("boldText", UIAccessibility.isBoldTextEnabled),
            ("reduceMotion", UIAccessibility.isReduceMotionEnabled),
            ("crossFade", UIAccessibility.prefersCrossFadeTransitions),
            ("reduceTransparency", UIAccessibility.isReduceTransparencyEnabled),
            ("darkerColors", UIAccessibility.isDarkerSystemColorsEnabled),
            ("buttonShapes", UIAccessibility.buttonShapesEnabled),
            ("onOffLabels", UIAccessibility.isOnOffSwitchLabelsEnabled),
            ("differentiateWithoutColor", UIAccessibility.shouldDifferentiateWithoutColor),
            ("invertColors", UIAccessibility.isInvertColorsEnabled),
            ("grayscale", UIAccessibility.isGrayscaleEnabled),
            ("videoAutoplay", UIAccessibility.isVideoAutoplayEnabled),
            ("horizontalText", __AXPrefersHorizontalTextLayout()),
            ("animatedImages", __AXAnimatedImagesEnabled()),
            ("nonBlinkingCursor", { if #available(iOS 18.0, *) { AccessibilitySettings.prefersNonBlinkingTextInsertionIndicator } else { false } }()),
            ("showBorders", { if #available(iOS 26.1, *) { AccessibilitySettings.showBordersEnabled } else { false } }()),
        ]
        let flags = values.map { "\($0.0)=\($0.1 ? 1 : 0)" }.joined(separator: " ")
        return "\(flags) style=\(traits.userInterfaceStyle.rawValue) size=\(traits.preferredContentSizeCategory.rawValue) contrast=\(traits.accessibilityContrast.rawValue) weight=\(traits.legibilityWeight.rawValue)"
    }

    static func statuses(_ reason: String, traits: UITraitCollection) {
        Log.write("STATUS \(reason) \(statusLine(traits: traits))")
    }

    static func fraction(_ value: CGFloat) -> String { String(format: "%.3f", value) }
}

final class ProbeApplication: UIApplication {
    private static let modifierNames: [(UIKeyModifierFlags, String)] = [
        (.shift, "shift"), (.control, "ctrl"), (.alternate, "alt"), (.command, "cmd"), (.alphaShift, "caps"),
    ]

    override func sendEvent(_ event: UIEvent) {
        if let presses = event as? UIPressesEvent {
            for press in presses.allPresses where press.phase == .began {
                if let key = press.key {
                    let mods = Self.modifierNames.filter { key.modifierFlags.contains($0.0) }.map(\.1).joined(separator: ",")
                    Log.write("KEY code=\(key.keyCode.rawValue) chars=\(key.charactersIgnoringModifiers.unicodeScalars.map { String($0.value) }.joined(separator: ",")) mods=\(mods)")
                } else {
                    Log.write("PRESS type=\(press.type.rawValue)")
                }
            }
        }
        if event.type == .touches {
            for touch in event.allTouches ?? [] where touch.phase == .began || touch.phase == .ended {
                guard let window = touch.window else { continue }
                let point = touch.location(in: window)
                let orientation = window.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? 0
                Log.write("TOUCH \(touch.phase == .began ? "began" : "ended") \(Log.fraction(point.x / window.bounds.width)) \(Log.fraction(point.y / window.bounds.height)) interface=\(orientation)")
            }
        }
        super.sendEvent(event)
    }
}

final class CustomContentView: UIView, AXCustomContentProvider {
    var accessibilityCustomContent: [AXCustomContent]! = {
        let breed = AXCustomContent(label: "Breed", value: "Corgi")
        breed.importance = .high
        return [AXCustomContent(label: "Age", value: "3 years"), breed]
    }()
}

final class GradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let gradient = layer as! CAGradientLayer
        gradient.colors = [UIColor.systemRed.cgColor, UIColor.systemYellow.cgColor, UIColor.systemBlue.cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
    }

    required init?(coder: NSCoder) { fatalError() }
}

struct SwiftUIProbe: View {
    @Environment(\.accessibilityPlayAnimatedImages) private var playAnimatedImages

    var body: some View {
        VStack {
            Text("Section").accessibilityAddTraits(.isHeader).accessibilityHeading(.h2)
            HStack { Text("Left"); Text("Right") }.accessibilityElement(children: .contain).accessibilityLabel("Group")
        }
        .onAppear { Log.write("ANIMATED \(playAnimatedImages ? 1 : 0)") }
        .onChange(of: playAnimatedImages) { _, value in Log.write("ANIMATED \(value ? 1 : 0)") }
    }
}

final class ProbeViewController: UIViewController {
    private var observers: [NSObjectProtocol] = []
    private var volume: NSKeyValueObservation?
    private var lastStatus = ""

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let header = UILabel()
        header.text = "Probe"
        header.font = .preferredFont(forTextStyle: .largeTitle)
        header.accessibilityTraits = .header

        let play = UIButton(type: .system)
        play.setTitle("Play", for: .normal)
        play.accessibilityHint = "Plays the video"
        play.accessibilityIdentifier = "play-button"
        play.accessibilityUserInputLabels = ["Play", "Start"]
        play.accessibilityLanguage = "en-US"
        play.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Delete") { _ in true },
                                           UIAccessibilityCustomAction(name: "Share") { _ in true }]
        play.addAction(UIAction { _ in Log.write("TAP play") }, for: .touchUpInside)

        let card = UIStackView(arrangedSubviews: [Self.label("Title"), Self.label("Subtitle")])
        card.axis = .vertical
        card.isAccessibilityElement = true
        card.accessibilityLabel = "Card, 2 lines"
        card.accessibilityIdentifier = "card"
        card.accessibilityContainerType = .semanticGroup

        let slider = UISlider()
        slider.value = 0.25
        slider.accessibilityLabel = "Volume"

        let toggle = UISwitch()
        toggle.isOn = true
        toggle.accessibilityLabel = "Wi-Fi"

        let field = UITextField()
        field.placeholder = "Email"
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        field.addAction(UIAction { _ in Log.write("TEXT \(field.text ?? "")") }, for: .editingChanged)

        let content = CustomContentView()
        content.isAccessibilityElement = true
        content.accessibilityLabel = "Dog"
        content.heightAnchor.constraint(equalToConstant: 30).isActive = true
        content.backgroundColor = .systemFill

        let disclosure = UIButton(type: .system)
        disclosure.setTitle("Details", for: .normal)
        if #available(iOS 18.0, *) {
            disclosure.accessibilityExpandedStatus = .expanded
        }
        disclosure.accessibilityTraits.insert(.toggleButton)

        let disabled = UIButton(type: .system)
        disabled.setTitle("Disabled", for: .normal)
        disabled.isEnabled = false

        let swiftUI = UIHostingController(rootView: SwiftUIProbe())
        addChild(swiftUI)
        swiftUI.view.heightAnchor.constraint(equalToConstant: 60).isActive = true

        let pair = UIStackView(arrangedSubviews: [Self.label("One"), Self.label("Two")])
        pair.axis = .horizontal
        pair.accessibilityLabel = "Pair"
        pair.accessibilityContainerType = .semanticGroup

        let backdrop = GradientView()
        backdrop.heightAnchor.constraint(equalToConstant: 120).isActive = true
        let glass: UIButton
        if #available(iOS 26.0, *) {
            glass = UIButton(configuration: .glass())
        } else {
            glass = UIButton(configuration: .filled())
        }
        glass.configuration?.title = "Glass"
        glass.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            glass.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor),
            glass.widthAnchor.constraint(equalToConstant: 200),
            glass.heightAnchor.constraint(equalToConstant: 80),
        ])

        let rows = (1...12).map { Self.label("Row \($0)") }
        let stack = UIStackView(arrangedSubviews: [header, play, card, slider, toggle, field, content, disclosure, disabled, swiftUI.view, pair, backdrop] + rows)
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
        ])
        swiftUI.didMove(toParent: self)
        view.layoutIfNeeded()
        content.accessibilityActivationPoint = content.convert(CGPoint(x: 10, y: 10), to: nil)

        Log.statuses("launch", traits: traitCollection)
        lastStatus = Log.statusLine(traits: traitCollection)

        let names: [Notification.Name] = [
            UIAccessibility.boldTextStatusDidChangeNotification, UIAccessibility.reduceMotionStatusDidChangeNotification,
            UIAccessibility.prefersCrossFadeTransitionsStatusDidChange, UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            UIAccessibility.darkerSystemColorsStatusDidChangeNotification, UIAccessibility.buttonShapesEnabledStatusDidChangeNotification,
            UIAccessibility.onOffSwitchLabelsDidChangeNotification, UIAccessibility.differentiateWithoutColorDidChangeNotification,
            UIAccessibility.invertColorsStatusDidChangeNotification, UIAccessibility.grayscaleStatusDidChangeNotification,
            UIAccessibility.videoAutoplayStatusDidChangeNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Log.statuses("notified:\(name.rawValue)", traits: self.traitCollection)
            }
        }
        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self,
                                 UITraitAccessibilityContrast.self, UITraitLegibilityWeight.self]) { (controller: ProbeViewController, _) in
            Log.statuses("traits", traits: controller.traitCollection)
        }
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let status = Log.statusLine(traits: self.traitCollection)
            if status != self.lastStatus {
                self.lastStatus = status
                Log.write("STATUS poll \(status)")
            }
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient)
        try? session.setActive(true)
        volume = session.observe(\.outputVolume, options: [.initial, .new]) { session, _ in
            Log.write("VOLUME \(session.outputVolume)")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        logOrientation()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.logOrientation() }
    }

    private func logOrientation() {
        Log.write("ORIENT interface=\(view.window?.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? 0)")
    }

    private static func label(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        return label
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ProbeViewController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) { Log.write("SCENE active") }
    func sceneWillResignActive(_ scene: UIScene) { Log.write("SCENE inactive") }
    func sceneDidEnterBackground(_ scene: UIScene) { Log.write("SCENE background") }
    func sceneWillEnterForeground(_ scene: UIScene) { Log.write("SCENE foreground") }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        Log.write("ARGS \(ProcessInfo.processInfo.arguments.dropFirst().joined(separator: " "))")
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, NSStringFromClass(ProbeApplication.self), NSStringFromClass(AppDelegate.self))
