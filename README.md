# simdrive

Drives a booted iOS or tvOS simulator's hardware keyboard, touchscreen, buttons, Apple TV Remote, orientation, pasteboard and foldable hinge from the command line, without Simulator.app or DeviceHub. It also reads the frontmost app's accessibility hierarchy and changes appearance, text size, Liquid Glass and accessibility settings. Every call prints one JSON line, so LLM agents can use it directly.

## Build

```sh
swift build -c release   # Xcode 27, macOS 26
.build/release/simdrive help
```

## Agent skill

[skills/simdrive/SKILL.md](skills/simdrive/SKILL.md) teaches an agent to use simdrive; [AGENTS.md](AGENTS.md) explains how to install it and how to extend simdrive.

## Use

```sh
simdrive list                                   # booted simulators
simdrive <udid|booted> <command>
```

| Command | Effect |
| --- | --- |
| `key <name\|char> [--mods cmd,shift,alt,ctrl] [--repeat N]` | Hardware key press: `tab`, `return`, `escape`, `left`, `f5`, `a`, `/`… |
| `type <text>` | Types US-layout characters; paste anything else |
| `tap <x> <y> [--display D]` | Touch |
| `swipe <x1> <y1> <x2> <y2> [--duration ms] [--edge top\|bottom\|left\|right] [--display D]` | Drag; `--edge` starts a system edge gesture |
| `button <name> [--repeat N] [--hold ms]` | Hardware or Apple TV Remote button, held 100 ms by default |
| `posture [closed\|half\|open]` | Sets or reads a foldable's hinge; returns once the hinge settles |
| `orientation [portrait\|landscape-left\|landscape-right\|upside-down]` | Sets or reads the device orientation |
| `pasteboard [text]` | Reads the device's pasteboard items (types and text), or replaces it with text |
| `screenshot <path.png> [--display D] [--max-dim N]` | Captures a screen, downscaled to 1024 px by default; the original is kept as `<path>.full.png` |
| `tree [<x> <y>] [--full]` | Lists the frontmost app's VoiceOver elements, or reads the element at a point; `--full` returns every node and field |
| `setting [<name> [<value>]]` | Lists every setting, or reads or changes one |
| `launch <bundle-id> [args...]` | Relaunches an app and waits until it is frontmost |
| `wait <ms>` | Pauses, for `run` |
| `run <steps.json\|->` | Runs a JSON array of commands, such as `["tap 0.5 0.5", ["key", "tab"]]`, stopping at the first failure |
| `doctor` | Reports the developer directory, displays, orientation, pasteboard, hinge, keyboard, frontmost app and appearance |
| `stop` | Ends the device's daemon and releases its input services |

Output is `{"ok":true,"result":…}`, or `{"ok":false,"error":…,"code":…}` with exit status 1.

### Results

Values use the command line's spellings, such as `landscape-left` and `half`.

| Command | `result` |
| --- | --- |
| `list` | `[{"udid", "name", "runtime", "deviceType"}]` |
| `key` | `{"key", "modifiers": [names], "count"}` |
| `type` | `{"characters"}` |
| `tap` | `{"display": index or null, "point": {"x", "y"}}`, the point as fractions of the screen |
| `swipe` | `{"display", "from": {"x", "y"}, "to": {"x", "y"}, "edge"}` |
| `button` | `{"button", "count"}` |
| `posture` | `{"angle": degrees, "posture": "closed", "half" or "open"}` |
| `orientation` | `{"orientation", "physical"}`: the interface's orientation, and the device's own, which may be `faceUp`, `faceDown` or `unknown` |
| `pasteboard` | Reading: `{"items": [{"types": [UTIs], "text"}]}`. Writing: `{"characters"}` |
| `screenshot` | `{"path", "width", "height", "fullPath", "fullWidth", "fullHeight", "display", "orientation"}`; `orientation` is null on devices that cannot rotate |
| `tree` | `{"app": {"name", "pid"}, "display", "elements": [element]}`, or `"root"` with `--full`. With a point: `{"app", "display", "point", "element"}`. Elements are described under [Accessibility](#accessibility) |
| `setting` | Listing: `{"settings": {name: value}}`. Otherwise `{"setting", "value"}`, the value read back after a change |
| `launch` | `{"bundleID", "pid"}` |
| `wait` | `{"waited": milliseconds}` |
| `run` | `{"steps": [each step's result]}` |
| `doctor` | `{"developerDirectory", "device", "state", "deviceType", "displays", "orientation", "pasteboard", "keyboard", "posture", "accessibility", "appearance"}`; `accessibility` is the frontmost app's `{"name", "pid"}`, and a failed check is `{"error"}` |
| `stop` | `{"stopped": whether a daemon ran}` |

### Coordinates

Values in 0–1 written with a decimal point (`0.5 0.25`, `1.0 0.0`) are fractions of the screen. Other values are pixels of the last screenshot's image, so `screenshot` then `tap 120 340` taps what the image shows at that pixel. Pixel taps fail once the device rotates, until a new screenshot.

Taps follow the interface's rotation, which simdrive reads from CoreSimulator with each screenshot, so they land right even when the app does not turn with the device. `launch` and `button home` forget the rotation, since a new app may rotate the interface without rotating the device; take a screenshot after other app switches before tapping.

### Buttons

`home`, `lock`, `volume-up`, `volume-down` and `siri` are the device's buttons. The Apple TV Remote adds `menu` (Back), `select`, `play-pause`, `up`, `down`, `left`, `right`, `channel-up` and `channel-down`; on tvOS `home` is the TV button and `lock` opens Control Center. `--hold 1000` long-presses, as for context menus.

### Apple TV

Remote buttons and the keyboard (`key down`, `key return`, typing into a focused text field) move focus and act on it. `tap`, `swipe`, `orientation` and `pasteboard` fail with `no-touchscreen`, `orientation-unsupported` and `pasteboard-unsupported`; screenshots report a null orientation.

### Pasteboard

`pasteboard` reads and writes the device's general pasteboard through CoreDevice, never the Mac's directly. A host that syncs pasteboards, such as DeviceHub, copies a write to the Mac clipboard, replacing what the user copied, and copies the user's later copies to the device. To enter text the keyboard cannot type: `pasteboard "Grüße"`, then `key v --mods cmd`.

### Foldables

On a foldable, `D` is `cover`, `inner` or a `simctl` display index. Commands default to the cover panel when closed and the inner panel otherwise.

### Accessibility

`tree` reads the frontmost app's accessibility hierarchy from the Mac through AccessibilityPlatformTranslation, as Simulator and idb do; nothing is installed in the guest. By default it lists what VoiceOver stops on, in hierarchy order, with what finds and acts on each element: `point`, `type`, `label`, `value`, `identifier`, `placeholder`, `traits`, `offscreen`, `focused` and `expanded`. Light elements leave out `value` while it repeats the placeholder, as an empty text field's does, and the trait `type` already names. It is a quarter of the full output's size or less.

`tree --full` returns XCUITest's whole snapshot of the app, nested, for debugging and accessibility audits. It lists every view and SwiftUI accessibility node, including the cells and labels inside controls that VoiceOver reads as one element. Each element has:

- `point`, where VoiceOver taps it, or its center when that lies outside it, and `frame`, its bounds, as fractions of the screen; `tap` takes `point` as it is.
- `voiceOver: true` when VoiceOver stops on it: an accessibility element outside other elements. VoiceOver skips its descendants. `offscreen: true` marks such an element outside the screen or its scroll view, which VoiceOver scrolls to.
- `type`, XCUIElement's element type, such as `button`, `cell` or `staticText`, and `traits`, UIKit's public accessibility traits, such as `button`, `selected`, `notEnabled`, `adjustable`, `header` and `toggleButton`.
- When set: `label`, `value`, `hint`, `identifier`, `placeholder`, `headingLevel`, `expanded`, `containerType`, `language`, `inputLabels` (Voice Control's names), `customActions`, `customContent` (`{"label", "value", "important"}`), `url`, `range` (an adjustable element's `{"min", "max", "value"}`), `focused` (the focus engine's focus, as on tvOS), `class`, `viewController` and `children`.

`tree <x> <y>` returns the element VoiceOver finds at a point, with its descendants under `--full`, or fails with `no-element`. On a foldable, both refer to the panel in use.

### Settings

`setting` lists every setting's value. `setting <name>` reads one; `setting <name> <value>` changes it, notifies running apps, and returns the value read back. Toggles take `on` or `off`. Settings apply to the whole simulator and persist, so set them back when done.

| Setting | Values | Apps read it as |
| --- | --- | --- |
| `appearance` | `light`, `dark` | `userInterfaceStyle` |
| `text-size` | `extra-small`, `small`, `medium`, `large`, `extra-large`, `extra-extra-large`, `extra-extra-extra-large`, `accessibility-medium` … `accessibility-extra-extra-extra-large` | `preferredContentSizeCategory` |
| `increase-contrast` | toggle | `accessibilityContrast` |
| `bold-text` | toggle | `isBoldTextEnabled`, `legibilityWeight` |
| `reduce-motion` | toggle | `isReduceMotionEnabled` |
| `prefer-cross-fade` | toggle | `prefersCrossFadeTransitions`, only while `reduce-motion` is on |
| `reduce-transparency` | toggle | `isReduceTransparencyEnabled` |
| `show-borders` | toggle | `buttonShapesEnabled`, `AccessibilitySettings.showBordersEnabled` |
| `on-off-labels` | toggle | `isOnOffSwitchLabelsEnabled` |
| `differentiate-without-color` | toggle | `shouldDifferentiateWithoutColor` |
| `prefer-horizontal-text` | toggle | `AccessibilitySettings.prefersHorizontalTextLayout` |
| `smart-invert` | toggle | `isInvertColorsEnabled` |
| `grayscale` | toggle | `isGrayscaleEnabled` |
| `autoplay-video-previews` | toggle, on by default | `isVideoAutoplayEnabled` |
| `autoplay-animated-images` | toggle, on by default | `AccessibilitySettings.animatedImagesEnabled`, `accessibilityPlayAnimatedImages` |
| `non-blinking-cursor` | toggle, iOS 18 and later | `AccessibilitySettings.prefersNonBlinkingTextInsertionIndicator` |
| `glass-tint` | 0 to 1, 0.5 by default, iOS 26 and later | Settings' Liquid Glass Tint Amount slider |

The first three go through `simctl ui`, which tvOS lacks: there they read `unsupported`, and changing them fails with `setting-unsupported`, as do settings on systems older than they are. The others are guest preferences followed by the Darwin notifications that UIKit and the accessibility cache listen for; iOS 17 and 18 apps miss some changes without the cache's. VoiceOver, Zoom, AssistiveTouch, Switch Control and Full Keyboard Access are left out: they take over input, or do not start from a preference.

### Daemon

The first command for a device starts a daemon that keeps the private-framework bindings loaded: the first call takes 2–8 s, later ones tens of milliseconds. The daemon releases its keyboard, touch and button services 30 s after the last input and exits after 10 idle minutes. A rebuilt binary or a different developer directory replaces it. Sockets and logs live in `/tmp/simdrive-<uid>/`. `--no-daemon` runs a command in-process.

The developer directory comes from `SIMDRIVE_DEVELOPER_DIR`, then `DEVELOPER_DIR`, then `xcode-select -p`.

## Limitations

- Simulators only; no physical devices.
- `type` covers the US layout; other text goes through the pasteboard, which a syncing host copies to the Mac.
- No swipes on the Apple TV Remote's touch surface; the directional buttons move focus instead.
- The iPhone Duo's cover panel accepts orientation changes, but its apps stay portrait.
- Until 30 s after simdrive's last input, the guest drops touches from other clients, such as clicks in DeviceHub or Simulator.app. `simdrive <udid> stop` releases its services at once. Driving while DeviceHub runs works.
- The guest ignores touches during transitions and batches events while busy, such as right after launch. Screenshot before acting.
- `tree` shows only what the app exposes to accessibility. A custom view marked as an accessibility element hides its subviews from the snapshot too; UIKit controls and cells list theirs.
- `offscreen` compares frames with the screen and scroll views, so an element covered by another, such as one behind a sheet, does not count as offscreen. The app's own visibility check hit-tests every element and times out on large screens.
- For a minute after a simulator's first boot, `tree` may fail with `accessibility-timeout`; retry.
- Built on CoreSimulator, CoreDevice, UniversalHIDKit and AccessibilityPlatformTranslation private API, so Xcode and macOS updates may break it. Tested with Xcode 27.0 and 27.2 on iPhone iOS 17.0, 18.3, 26.5 and 27.0, iPad iOS 26.5 and 27.0, iPhone Duo iOS 27.2 and Apple TV 4K tvOS simulators.

## Follow-up

- Acting on elements by label rather than by point, such as pressing or incrementing through `AXPress` and `AXIncrement`.
- VoiceOver's spoken text and accessibility audits, through the guest's `axauditd`, which speaks DTX over XPC.
- Apple TV Remote touch-surface swipes, through SimulatorKit's `IndigoHIDMessageForTrackpadMoveEvent`, as NeoSimulator sends them.

## Credits

The guest HID, posture and keyboard-translation approach comes from [NeoSimulator](https://github.com/lynnswap/NeoSimulator) (MIT); see [THIRD_PARTY.md](THIRD_PARTY.md). Native calls go through [ABIBridge](https://github.com/lynnswap/ABIBridge). [idb](https://github.com/facebook/idb) showed the way to read a simulator's accessibility through AccessibilityPlatformTranslation.
