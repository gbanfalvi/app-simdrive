# simdrive

Drives a booted iOS or tvOS simulator's hardware keyboard, touchscreen, buttons, Apple TV Remote, orientation, pasteboard and foldable hinge from the command line, without Simulator.app or DeviceHub. Every call prints one JSON line, so LLM agents can use it directly.

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
| `launch <bundle-id> [args...]` | Relaunches an app |
| `wait <ms>` | Pauses, for `run` |
| `run <steps.json\|->` | Runs a JSON array of commands, such as `["tap 0.5 0.5", ["key", "tab"]]`, stopping at the first failure |
| `doctor` | Reports the developer directory, displays, orientation, pasteboard, hinge and keyboard |
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
| `launch` | `{"bundleID", "pid"}` |
| `wait` | `{"waited": milliseconds}` |
| `run` | `{"steps": [each step's result]}` |
| `doctor` | `{"developerDirectory", "device", "state", "deviceType", "displays", "orientation", "pasteboard", "keyboard", "posture"}`; a failed check is `{"error"}` |
| `stop` | `{"stopped": whether a daemon ran}` |

### Coordinates

Values in 0–1 written with a decimal point (`0.5 0.25`, `1.0 0.0`) are fractions of the screen. Other values are pixels of the last screenshot's image, so `screenshot` then `tap 120 340` taps what the image shows at that pixel. Pixel taps fail once the device rotates, until a new screenshot.

Taps follow the screen's rotation, which simdrive reads from screenshots. `launch` and `button home` forget the rotation, since a new app may rotate the interface without rotating the device; take a screenshot after other app switches before tapping.

### Buttons

`home`, `lock`, `volume-up`, `volume-down` and `siri` are the device's buttons. The Apple TV Remote adds `menu` (Back), `select`, `play-pause`, `up`, `down`, `left`, `right`, `channel-up` and `channel-down`; on tvOS `home` is the TV button and `lock` opens Control Center. `--hold 1000` long-presses, as for context menus.

### Apple TV

Remote buttons and the keyboard (`key down`, `key return`, typing into a focused text field) move focus and act on it. `tap`, `swipe`, `orientation` and `pasteboard` fail with `no-touchscreen`, `orientation-unsupported` and `pasteboard-unsupported`; screenshots report a null orientation.

### Pasteboard

`pasteboard` reads and writes the device's general pasteboard through CoreDevice, never the Mac's directly. A host that syncs pasteboards, such as DeviceHub, copies a write to the Mac clipboard, replacing what the user copied, and copies the user's later copies to the device. To enter text the keyboard cannot type: `pasteboard "Grüße"`, then `key v --mods cmd`.

### Foldables

On a foldable, `D` is `cover`, `inner` or a `simctl` display index. Commands default to the cover panel when closed and the inner panel otherwise.

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
- Built on CoreSimulator, CoreDevice and UniversalHIDKit private API, so Xcode updates may break it. Tested with Xcode 27.0 and 27.2 on iPhone iOS 27.0, iPad iOS 26.5 and 27.0, iPhone Duo iOS 27.2 and Apple TV 4K tvOS simulators.

## Follow-up

- An accessibility-tree dump (element labels, frames and traits) would let agents target elements without reading screenshots.
- Apple TV Remote touch-surface swipes, through SimulatorKit's `IndigoHIDMessageForTrackpadMoveEvent`, as NeoSimulator sends them.

## Credits

The guest HID, posture and keyboard-translation approach comes from [NeoSimulator](https://github.com/lynnswap/NeoSimulator) (MIT); see [THIRD_PARTY.md](THIRD_PARTY.md). Native calls go through [ABIBridge](https://github.com/lynnswap/ABIBridge).
