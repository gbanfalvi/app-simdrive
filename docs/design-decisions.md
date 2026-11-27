# Design decisions

## Origin

simdrive grew out of debugging an app on Xcode 27 simulators: a layout bug on the iPhone Duo when its hinge opens, and hardware-keyboard focus. Both needed an agent to press keys, tap, and fold the Duo without a person at DeviceHub. NeoSimulator already drove the Duo's hinge and the guest's HID services, so its input code was ported into a standalone CLI.

## A CLI that prints one JSON line

Agents already have a shell. A CLI needs no MCP server, no client library and no protocol negotiation, and the same binary serves people, scripts and the evaluation matrix. Every call prints exactly one line with a stable `code` on failure, so an agent branches on codes rather than on prose.

## Guest services, not front ends

Input goes to the guest's own HID services, as DeviceHub and NeoSimulator send it, so it works the same with DeviceHub open, NeoSimulator open, or nothing at all. Rejected:

- **SimulatorKit's Indigo HID** (`IndigoHIDMessageForKeyboardArbitrary` through `SimDeviceLegacyHIDClient`), the path idb uses. On Xcode 27 it sends without error but nothing reaches apps, on iPad or Duo, with or without `setHardwareKeyboardEnabled:`. AXe has since found the likely cause: from CoreSimulator 1155.4, a running `dtuhidd`, the guest's CoreDevice HID daemon, suppresses the legacy `ExternalKeyboardService`. simdrive's own guest connections start `dtuhidd`, so Indigo cannot work alongside them (unverified in simdrive).
- **Driving a front end**: pressing NeoSimulator's posture buttons through AXUIElement, or DeviceHub through `CGEventPostToPid` or System Events. Each needs that app running with a visible window and accessibility trust, and breaks when its UI changes.
- **XCUITest**: needs a test runner per app, and could not tap the Duo's inner panel.
- **Shipping inside NeoSimulator**: would tie simdrive to a GUI app and its releases.

## One core, two transports for physical devices

From iOS and tvOS 27, a device's developer disk image runs the same CoreDevice daemons a simulator's guest runs, and simdrive's own messages worked unchanged over CoreDevice's RemoteXPC connection to them (N35). So physical devices share the drivers, and the kinds split only in how a `Guest` connects, with whatever needs CoreSimulator kept in one place in the session. Rejected:

- **CoreDevice's typed capabilities** (`HIDDigitizer.send`), as NeoSimulator drives devices: a second set of drivers, though the raw messages already work.
- **An XCTest runner** for input: 0.7–3.7 s a touch, and signing. It remains the only route to a device's accessibility tree (N37).
- **iOS 17–26:** their disk images lack these daemons, so no input reaches them without a runner.

Choices made with the user:
- Commands without a device route fail with the capability's own `-unsupported` code.
- Because a set orientation holds on a device, the session puts back the reading it found when it closes.
- A device is named by CoreDevice's identifier or its hardware UDID, while `booted` keeps meaning simulators.

## Port NeoSimulator onto ABIBridge

The guest HID, keyboard translation, posture and pasteboard code came from NeoSimulator at `1dfc4af` (MIT; see [THIRD_PARTY.md](../THIRD_PARTY.md)), trimmed to the main keyboard (no per-Mac keyboard mirroring), the digitizer, buttons, orientation, pasteboard and posture. ABIBridge is pinned `exact: "0.20.4"`, the version NeoSimulator uses, because a different ABIBridge can change how the same symbols bind. When an Xcode update breaks a binding, diff NeoSimulator upstream for the ported files first: it tracks Xcode closely.

## A daemon per device

- **Cost**: resolving the private bindings takes about 2 s per process; a warm daemon answers in tens of milliseconds.
- **State**: guest services last as long as their XPC connection. A one-shot process would attach and detach a hardware keyboard on every call, which can reset keyboard focus and shows and hides the software keyboard.
- **One per UDID**, so devices never share a queue and a stuck guest blocks only its own device.
- **Replaced on rebuild or developer-directory change** (`BuildStamp`), so a stale binary never answers. A modification time is cheaper than hashing the binary on every call.
- **`--no-daemon`** stays for debugging and for the matrix's comparisons.

## Release inputs after 30 s

While simdrive holds the digitizer, the guest drops touches from every other client, including clicks in DeviceHub. While its keyboard exists, the guest counts a hardware keyboard as connected and hides the software keyboard. Releasing keyboard, touch and button services 30 s after the last input bounds both effects; `stop` releases them at once.

## Fractions and pixels

- A number with a decimal point in 0–1 is a fraction of the screen; anything else is a pixel of the last screenshot's image. Agents read pixels off an image and think in fractions from a tree; both work without a flag.
- Pixel taps fail with `stale-screenshot` after rotation instead of guessing, since the image no longer matches the screen.
- Fractions need the screen's aspect and rotation, so the first fraction with no record reads them from the framebuffer, or takes a full-resolution calibration screenshot when it cannot. Records persist in `<udid>.screens.json`, keyed by digitizer target and reset on reboot.
- `launch` and `button home` forget records: a new foreground app may rotate the interface without the device rotating.

## Interface orientation from CoreSimulator

The digitizer takes points in the panel's native orientation; `simctl` screenshots follow the interface. Mapping by device orientation alone fails when the app does not rotate with the device, and flipped taps 180° on the Duo's inner panel. simdrive reads each screen's interface orientation from CoreSimulator's screen adapter when it captures, and falls back to the device orientation only when CoreSimulator reports none. Reading it in process replaced parsing `simctl io enumerate`, saving about 1 s per screenshot or calibration.

## Screenshots from the framebuffer

simdrive copies each screen's framebuffer surface and rotates it upright as `simctl` does, instead of spawning `simctl io screenshot`. A default screenshot fell from 760 ms to 340 ms on an iPhone and from 1.75 s to 80 ms on an iPad, and calibration needs no image. The cost is the Dynamic Island and the Duo's closed-cover camera hole, which show as black where `simctl` masks them; agents read the same app pixels either way. `simctl` remains the fallback when a screen has no readable surface.

## `simctl` directly

simdrive runs CoreSimulator's own `simctl` (`/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl`), falling back to `xcrun simctl`. The `xcrun` wrapper adds about 0.8 s per call. `DEVELOPER_DIR` in the child's environment keeps it on the chosen Xcode.

## Launch waits for the front

`launch` relaunches (`--terminate-running-process`) so the app starts from its launch screen with the given arguments. `simctl launch` returns seconds before the app is active, so under load the next step's input arrived before the app could take it. simdrive now polls the accessibility server's frontmost pid every 100 ms, for up to 30 s, and fails with `launch-not-frontmost` otherwise. 10 s was too short: freshly booted iOS 17 and 18 simulators, with six booted at once, took 20–67 s. When accessibility is unavailable, `launch` returns without waiting.

`launch` first writes `ApplicationAccessibilityEnabled`, about 0.4 s, since an app launched while it is off never answers accessibility reads and iOS 27 turns it off with Full Keyboard Access (F18). When `tree` finds an empty frame and the preference off, it reports `app-accessibility-off` instead of `accessibility-translation`. It still takes the read's 20 s deadline to get there: the same empty frame comes from a launching app and after boot, where retrying is what works.

## Accessibility from the Mac

`tree` reads the guest's accessibility server through AccessibilityPlatformTranslation, as Simulator and idb do, so nothing is installed in the guest and any app works, including SpringBoard.

- **One snapshot, not a walk.** Reading attributes element by element costs a guest round trip each. XCUITest's `AXTestingSnapshotParameterizedAttribute` returns a subtree with chosen attributes in one request: about 45 ms for about 100 nodes. It also lists the cells and labels inside UIKit controls that VoiceOver reads as one element.
- **A whitelist of attribute numbers.** Some numbers crash the app or return whole subtrees, and the visibility attribute hit-tests every node, which times out on large screens. `offscreen` is computed from frames instead.
- **Light by default.** The full tree costs agents tokens. The light list keeps what finds and acts on VoiceOver's elements, drops values that repeat the placeholder and traits the type already names, and is a quarter of the full size or less. Custom content costs a request per element, so only `--full` reads it.
- **No actions yet.** Tapping an element's `point` covers navigation; `AXPress` and `AXIncrement` are follow-ups.
- **No reads before a screen starts.** A read made in the first seconds of a boot is thought to leave the server unanswering until a reboot (F15), so the first read waits up to 60 s for CoreSimulator to report a started screen, then fails with the retryable `simulator-starting`.
- **Warm-up only in the daemon.** A daemon's new session reads once in the background so the first `tree` is quick; a one-shot process could exit with that read in flight and crash. XCTest's bootstrap was tried as a faster start and rejected (I16).

## Settings as a catalog

Each setting is one row in `SettingCatalog`, with no new command. Three are `SimDevice` interface options, which `simctl ui` also uses; VoiceOver and the color filter are CoreDevice setting actions, which the guest applies itself; `slow-animations` is a Darwin notification's state, set and posted, where `SimDevice supportsFeature:` says the guest keeps it; the rest are guest preferences plus the Darwin notifications that UIKit and the accessibility cache listen for.

- Preferences are written and read with `simctl spawn <udid> defaults`, not the plist on disk, since `cfprefsd` caches and may not flush. Notifications go through `SimDevice postDarwinNotification:error:` instead of a second spawn.
- Setting actions go straight to the guest service, not through `xcrun devicectl`, which first shipped them (N20) at about 3 s a call against tens of milliseconds (I10). The cost is private message shapes that an Xcode update can move, as 27.3 moved `executionLocation`.
- A row stays only if a running probe app sees the change on the oldest and newest runtimes; candidates it did not see were dropped. The CoreDevice rows are the exception so far, checked by reading back (I26).
- VoiceOver is offered since N20, as AXe and NeoSimulator offer it, though it may change how taps and keys land (I26). Zoom, AssistiveTouch and Switch Control stay out: they take over input, which would break simdrive's own.
- `set` returns the value read back, so an agent sees what took effect.

## Pasteboard through CoreDevice

The Mac clipboard is never touched: simdrive converts through a uniquely named `NSPasteboard`, and CoreDevice moves the snapshot to the guest. A syncing host such as DeviceHub still copies a guest write to the Mac clipboard, so writes need the user's consent, and the matrix writes only with `--pasteboard`.

## `type` uses the guest's own layout data

UniversalHIDKit's observer reads the key from the key code alone, not from the event's characters, and the guest decodes keys with its hardware keyboard layout. So `type` reads the active layout from the guest's keyboard preferences, as AXe does, and inverts the runtime's `uchr` data for it, which `UCKeyTranslate` reads by HID usage. On US it keeps its fixed table and loads nothing. Anything else goes through the pasteboard and `key v --mods cmd`.

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

## Element taps wait for still pixels

UIKit ignores touches while a transition animates, but the accessibility tree places an element at its final point from the start, so `tap --label` could tap a system alert before SpringBoard took touches and return `ok` (F29). Element taps now sample the 44 points around the tap point from the framebuffer every 25 ms, copying only those rows, and tap once they have not changed for 150 ms, or after 1.5 s. On the URL alert, the pixels stopped changing within one sample of the end of SpringBoard's ignore window. 150 ms outlasts the ~120 ms after the alert reaches the tree before its first frame is drawn. Rejected: waiting for two tree reads to agree, since the frames are final from the first; a fixed sleep, which costs every tap and is too short for slow transitions; a whole-element sample, which large elements with moving content, such as a cell holding a spinner, would never pass. Taps at coordinates and swipes do not wait: the agent chose the moment.

## Posture waits for the hinge

`posture` sends the target angle, waits for the reported angle to fall in the posture's range, then waits until it holds still for 400 ms, so the next screenshot shows the finished layout. The hinge settles near the requested angle, not on it, hence ranges.
