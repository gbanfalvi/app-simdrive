# Design decisions

## Origin

simdrive grew out of debugging an app on Xcode 27 simulators: a layout bug on the iPhone Duo when its hinge opens, and hardware-keyboard focus. Both needed an agent to press keys, tap, and fold the Duo without a person at DeviceHub. NeoSimulator already drove the Duo's hinge and the guest's HID services, so its input code was ported into a standalone CLI.

## A CLI that prints one JSON line

Agents already have a shell. A CLI needs no MCP server, no client library and no protocol negotiation, and the same binary serves people, scripts and the evaluation matrix. Every call prints exactly one line with a stable `code` on failure, so an agent branches on codes rather than on prose.

## Guest services, not front ends

Input goes to the guest's own HID services, as DeviceHub and NeoSimulator send it, so it works the same with DeviceHub open, NeoSimulator open, or nothing at all. Rejected:

- **SimulatorKit's Indigo HID** (`IndigoHIDMessageForKeyboardArbitrary` through `SimDeviceLegacyHIDClient`), the path idb uses. On Xcode 27 it sends without error but nothing reaches apps, on iPad or Duo, with or without `setHardwareKeyboardEnabled:`.
- **Driving a front end**: pressing NeoSimulator's posture buttons through AXUIElement, or DeviceHub through `CGEventPostToPid` or System Events. Each needs that app running with a visible window and accessibility trust, and breaks when its UI changes.
- **XCUITest**: needs a test runner per app, and could not tap the Duo's inner panel.
- **Shipping inside NeoSimulator**: would tie simdrive to a GUI app and its releases.

## Port NeoSimulator onto ABIBridge

The guest HID, keyboard translation, posture and pasteboard code came from NeoSimulator at `1dfc4af` (MIT; see [THIRD_PARTY.md](../THIRD_PARTY.md)), trimmed to the main keyboard (no per-Mac keyboard mirroring), the digitizer, buttons, orientation, pasteboard and posture. ABIBridge is pinned `exact: "0.19.1"`, the version NeoSimulator uses, because a different ABIBridge can change how the same symbols bind. When an Xcode update breaks a binding, diff NeoSimulator upstream for the ported files first: it tracks Xcode closely.

## A daemon per device

- **Cost**: resolving the private bindings takes 2–8 s per process; a warm daemon answers in tens of milliseconds.
- **State**: guest services last as long as their XPC connection. A one-shot process would attach and detach a hardware keyboard on every call, which can reset keyboard focus and shows and hides the software keyboard.
- **One per UDID**, so devices never share a queue and a stuck guest blocks only its own device.
- **Replaced on rebuild or developer-directory change** (`BuildStamp`), so a stale binary never answers. A modification time is cheaper than hashing the binary on every call.
- **`--no-daemon`** stays for debugging and for the matrix's comparisons.

## Release inputs after 30 s

While simdrive holds the digitizer, the guest drops touches from every other client, including clicks in DeviceHub. While its keyboard exists, the guest counts a hardware keyboard as connected and hides the software keyboard. Releasing keyboard, touch and button services 30 s after the last input bounds both effects; `stop` releases them at once.

## Fractions and pixels

- A number with a decimal point in 0–1 is a fraction of the screen; anything else is a pixel of the last screenshot's image. Agents read pixels off an image and think in fractions from a tree; both work without a flag.
- Pixel taps fail with `stale-screenshot` after rotation instead of guessing, since the image no longer matches the screen.
- Fractions need the screen's aspect and rotation, so the first fraction with no record takes a full-resolution calibration screenshot. Records persist in `<udid>.screens.json`, keyed by digitizer target and reset on reboot.
- `launch` and `button home` forget records: a new foreground app may rotate the interface without the device rotating.

## Interface orientation from CoreSimulator

The digitizer takes points in the panel's native orientation; `simctl` screenshots follow the interface. Mapping by device orientation alone fails when the app does not rotate with the device, and flipped taps 180° on the Duo's inner panel. simdrive reads each screen's interface orientation from CoreSimulator's screen adapter when it captures, and falls back to the device orientation only when CoreSimulator reports none. Reading it in process replaced parsing `simctl io enumerate`, saving about 1 s per screenshot or calibration.

## `simctl` directly

simdrive runs CoreSimulator's own `simctl` (`/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl`), falling back to `xcrun simctl`. The `xcrun` wrapper adds about 0.8 s per call. `DEVELOPER_DIR` in the child's environment keeps it on the chosen Xcode.

## Launch waits for the front

`launch` relaunches (`--terminate-running-process`) so the app starts from its launch screen with the given arguments. `simctl launch` returns seconds before the app is active, so under load the next step's input arrived before the app could take it. simdrive now polls the accessibility server's frontmost pid every 100 ms, for up to 30 s, and fails with `launch-not-frontmost` otherwise. 10 s was too short: freshly booted iOS 17 and 18 simulators, with six booted at once, took 20–67 s. When accessibility is unavailable, `launch` returns without waiting.

## Accessibility from the Mac

`tree` reads the guest's accessibility server through AccessibilityPlatformTranslation, as Simulator and idb do, so nothing is installed in the guest and any app works, including SpringBoard.

- **One snapshot, not a walk.** Reading attributes element by element costs a guest round trip each. XCUITest's `AXTestingSnapshotParameterizedAttribute` returns a subtree with chosen attributes in one request: about 45 ms for about 100 nodes. It also lists the cells and labels inside UIKit controls that VoiceOver reads as one element.
- **A whitelist of attribute numbers.** Some numbers crash the app or return whole subtrees, and the visibility attribute hit-tests every node, which times out on large screens. `offscreen` is computed from frames instead.
- **Light by default.** The full tree costs agents tokens. The light list keeps what finds and acts on VoiceOver's elements, drops values that repeat the placeholder and traits the type already names, and is a quarter of the full size or less. Custom content costs a request per element, so only `--full` reads it.
- **No actions yet.** Tapping an element's `point` covers navigation; `AXPress` and `AXIncrement` are follow-ups.

## Settings as a catalog

Each setting is one row in `SettingCatalog`, with no new command. Three go through `simctl ui`; the rest are guest preferences plus the Darwin notifications that UIKit and the accessibility cache listen for.

- Preferences are written and read with `simctl spawn <udid> defaults`, not the plist on disk, since `cfprefsd` caches and may not flush. Notifications go through `SimDevice postDarwinNotification:error:` instead of a second spawn.
- A row stays only if a running probe app sees the change on the oldest and newest runtimes; candidates it did not see were dropped.
- Left out: VoiceOver, Zoom, AssistiveTouch and Switch Control take over input, which would break simdrive's own; VoiceOver does not speak in the simulator anyway.
- `set` returns the value read back, so an agent sees what took effect.

## Pasteboard through CoreDevice

The Mac clipboard is never touched: simdrive converts through a uniquely named `NSPasteboard`, and CoreDevice moves the snapshot to the guest. A syncing host such as DeviceHub still copies a guest write to the Mac clipboard, so writes need the user's consent, and the matrix writes only with `--pasteboard`.

## `type` covers the US layout

UniversalHIDKit's observer reads the key from the key code alone, not from the event's characters, so `type` maps each character to a US key code and shift. Anything else goes through the pasteboard and `key v --mods cmd`, rather than guessing at other layouts.

## Logs as digests behind a cursor

Agents otherwise run `simctl spawn log stream` in the background and read the whole output, mostly system noise, or `log show` with a guessed window. `logs` returns only what is new and relevant, in one call.

- **A cursor, not a window.** Each read starts where the cursor's last one ended, so nothing repeats or slips between reads. Named cursors let independent watchers share a device; `--peek` rereads.
- **The launched app by default.** `launch` records the app, so a bare `logs` needs no predicate. Its executable comes from the bundle's `CFBundleExecutable`, read once and cached.
- **Compact entries.** Relative `ms`, fields left out when filtered or default, consecutive repeats merged, a limit and a width, and `dropped` to say what was cut. System libraries write about 98% of an app process's entries, so app scopes keep theirs only from `error` up.
- **`--until` without a race.** It attaches `log stream` first, then reads the history since the cursor, so an entry logged before the call, or while it attaches, still counts. `log show` alone would poll; `log stream` alone would miss what came before.
- **Outside the daemon.** The daemon serializes requests, so a waiting `logs` there would hold back input. Top-level `logs` runs in the client; inside `run`, it waits on purpose, starting at the previous step's start.
- **`run --logs` reads once.** One `log show` after the steps, split by each step's start, costs less than a read per step.
- **stdout and stderr from `launch`.** Apps' `print` and Swift runtime errors never reach the unified log. `simctl launch --stdout --stderr` captures them, with `NSUnbufferedIO` so lines arrive as printed.
- **Crash summaries, not reports.** A report is hundreds of lines of JSON; the summary keeps the exception and the top 10 frames, preferring the last exception's backtrace, with the report's path for more.

## Posture waits for the hinge

`posture` sends the target angle, waits for the reported angle to fall in the posture's range, then waits until it holds still for 400 ms, so the next screenshot shows the finished layout. The hinge settles near the requested angle, not on it, hence ranges.
