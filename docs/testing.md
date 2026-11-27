# Testing

## Unit tests

`swift test` covers pure logic: parsing, step lists, key maps, screen mapping, display listings, the setting catalog, JSON, accessibility element decoding, `LazyCapability`, log queries and digests, and crash report summaries from an inline report. None needs a simulator. Anything that touches a guest is checked by the matrix instead.

## The evaluation matrix

A command that returns `ok` may still have been dropped by the guest, so `Evaluation/matrix.py` checks effects, not replies.

```sh
swift build -c release
Evaluation/matrix.py <udid>                         # every section
Evaluation/matrix.py <udid> --only tree,tap         # some sections
Evaluation/matrix.py <udid> --pasteboard            # also write the pasteboard; needs the user's consent
Evaluation/matrix.py <udid> --timing --label base   # time common commands into .build/evaluation
SIMDRIVE=/path/to/other/simdrive Evaluation/matrix.py <udid> --timing --label other
Evaluation/fresh.py [--device 'iPhone Duo'] [--runtime 27.2] [--only …]   # on a simulator created and cold-booted for the run
```

`Evaluation/fresh.py` creates a simulator, waits for `bootstatus`, runs the matrix with the remaining arguments, and deletes the simulator when every check passes. A failing run keeps it and prints how to delete it. Use it for changes to opening a session, booting or the first command: a long-used simulator has lost the first-boot alerts, the slow accessibility start and the unstarted screen that such changes meet.

- **iPhones and iPads** install the probe app and check the tree, light tree, taps, keys, typing, orientation with hit tests and taps in each landscape, buttons (home, lock and unlock, Siri, volume), edge swipes, `run`, settings as the app sees them, the pasteboard, and logs: a tap's entries and stdout, the cursor, `run --logs`, `--until` inside and beside `run`, `log-timeout`, and a crash's stderr and summary. The crash section ends by relaunching the probe.
- **Foldables** replace the orientation and button sections with every posture, checking that screenshots and trees follow the expected panel.
- **Apple TV** has no probe; it drives Settings and checks focus movement, hit tests and the expected `no-touchscreen`, `orientation-unsupported` and `setting-unsupported` errors.
- Settings are read at the start and restored when the run completes, and the run's daemon is stopped. An interrupted run restores nothing.
- **Physical devices** (device mode) start when the UDID is a device's from `simdrive list`, or its hardware UDID.
  - **Every device:** the run checks `list`, `doctor` and `screenshot`, and that each command without a device route fails with its `-unsupported` code.
  - **iPhones and iPads** install the probe and check what it logs, with no tree:
    - taps and swipes, `pinch` and `rotate`, keys and typing, at the controls the probe's `LAYOUT` line places
    - orientation, then back to portrait
    - volume, Home and the bottom-edge swipe
    - `run`, a missing app's `uninstall` and `openurl`
    - `logs`: stdout after a tap, and a crash's stderr and report summary
    - the settings CoreDevice's actions reach, each set and put back
  - **Building the probe** needs `SIMDRIVE_TEAM`, the team whose development profile signs it. `build-probe.sh --device <hardware-udid> <team>` builds it with `xcodebuild` from `Evaluation/Probe/AXProbe.xcodeproj`, creating the profile and registering the device through the Mac's Xcode account.
  - **The probe's log** is copied off the device with `devicectl` on each read, so waits are three times longer.
  - **Apple TVs** check that `button left` moves focus, by comparing screenshots, and set appearance and put it back.
  - **A device is its owner's:** the run puts back every setting and the orientation, never writes the pasteboard unless given `--pasteboard`, and presses neither Lock nor Siri.

Results at v0.0.2: iPhone iOS 27 94/94, iOS 26 94/94, iOS 18 94/94, iOS 17 93/93, Duo 87/87, Apple TV 15/15.

Results at v0.1.0: a new iPhone 17, iOS 27.2, 125/125 for the whole matrix (before I10). After I10, the `settings` section: iOS 27.2 45/45, iOS 26.5 41/41, iOS 17.0 40/40. After release, on new simulators: Duo iOS 27.2 124/124, Apple TV tvOS 18.0 15/15, iPhone 16 iOS 18.0 128/128.

Results at v0.1.1, by section on new simulators as each change landed, not one whole run: iPhone 17, iOS 27.2: the whole matrix 132/132 after F29, `tap` 44/44, `tree,keys` 39/39, `services` 12/12, `settings` 47/47; iPhone 15, iOS 17.0: `tree,tap,misc` 49/49, `buttons` 12/12, `settings` 42/42; iPhone Duo, iOS 27.2: the whole matrix 121/124 after F29, failures under parallel load (F30), then `logs,settings` 76/76.

Results at v0.1.2, on new simulators: iPhone 17, iOS 27.2: the whole matrix 156/157 before F31's status-bar fix and F24's tokenless request, then `tree,tap` 56/56, `services` 12/12 twice, `settings` 49/49 and 47/47; iPhone Duo, iOS 27.2: `tree,tap,posture,buttons` 64/65, the failure `tree --app` before F24's fix, then `tree,tap` 55/55; iPhone 15, iOS 17.0 at 0d2c5fa: 150/152, failing `privacy grant photos` (F36) and a sheet-transition tap (F37).

Results at v0.2.0: the whole matrix on a new iPhone 17, iOS 27.2, 157/157 with one retried launch. Device mode at N35 (2026-11-27): iPhone 15 Pro, iOS 27.2.1 over USB, 48/48 in about 100 s; Apple TV 4K, tvOS 27.2.1 over Wi-Fi, 20/20.

Results at v0.2.1, after device wake and logs (N36, N38): the whole matrix on a new iPhone 17, iOS 27.2, 157/157; device mode on the iPhone 15 Pro, 51/51 with Auto-Lock set to Never, and on the Apple TV, 20/20. A device with a passcode that locks mid-run fails every launch, so device mode refuses to start on a locked device.

## The probe app

`Evaluation/build-probe.sh [udid]` builds `AXProbe.app` with `swiftc` against the iOS simulator SDK, with no Xcode project, signs it ad hoc and optionally installs it. Its minimum OS, iOS 17, comes from `Evaluation/Probe/Info.plist`. Bundle ID `com.simdrive.axprobe`.

It appends lines to `Documents/probe.log` in its data container:

| Line | Logged when |
| --- | --- |
| `KEY code=… chars=… mods=…` | A hardware key press reaches `pressesBegan` |
| `PRESS type=…` | A press that carries no key |
| `TOUCH began\|ended <x> <y> interface=…` | A touch reaches the window, in fractions |
| `TEXT …` | The text field changes |
| `STATUS …` | An accessibility status or trait collection changes, with every value the settings drive |
| `ORIENT interface=…` | The interface rotates, as a `UIInterfaceOrientation` raw value |
| `SCENE active\|inactive\|background\|foreground` | The scene's state changes |
| `ARGS …` | At launch, with its arguments |
| `TAP play` | The Play button fires; it also logs `TAP play` and `TAP play error` to the unified log (subsystem `simdrive.probe`) and prints `TAP play stdout` |
| `VOLUME …` | The output volume changes, which the simulator never reports |
| `LAYOUT play=x,y field=x,y` | The screen appears, with the centers of Play and the text field as window fractions, which device mode taps |

The log outlives runs. The matrix notes its line count before each action and matches only later lines.

Launched with `-probeLandscape`, the probe presents a landscape-only screen 3 s after its scene becomes active and logs `LANDSCAPE interface=…`. On an upright iPhone that turns the interface alone, with no launch, URL or Home press, which the matrix's `tap` section uses to check that taps follow it.

Launched with `-probeCrash`, the probe calls `fatalError("probe crash")` 2 s after its scene becomes active. ReportCrash reports a repeat of the same crash only by updating the earlier report, so the matrix falls back to `logs --since 24h` when no new report arrives within 90 s.

`ORIENT` uses UIKit's numbering, so device `landscape-left` logs 3 and `landscape-right` 4: the reverse of CoreSimulator's `uiOrientation` for the same rotation.

## Keeping results trustworthy

- **Use your own simulators.** Create them with `xcrun simctl create`, and leave other simulators and their settings alone.
- **One matrix at a time per Mac when possible.** Several booted simulators slow each other: launches took up to 67 s with six booted, and `swipe scrolls` fails intermittently under load. Rerun a single failure alone before investigating it.
- **Wake the display first.** An idle iPhone simulator's display sleeps and drops rotations and the first touch; see [device behavior](device-behavior.md#iphone-and-ipad).
- **Keep a failing simulator until the failure is understood.** Deleting it loses the guest log, its state and the only reproduction; delete it once the cause is found or a fresh simulator reproduces it.
- **One-shot runs can fail where the daemon does not.** A `--no-daemon` process exits right after its command, so work it left in the background races the exit. Repeat a one-shot command (20 runs found nothing after the fix where one matrix run had crashed) when a change starts background work.
- **Check each commit, not just the last.** `scripts/check-commits [<range>]` builds and tests every commit in the range, by default the unpushed ones, in a temporary worktree. Run it after splitting one working tree into several commits.
- **Clean up.** Stop the daemons you started (`simdrive <udid> stop`), return the Duo to its original posture and devices to portrait, and shut down the runtimes you booted.
- **Compare timings in rounds.** `tree` timings are bimodal, so one round's median can swing by 100 ms or more between identical builds. Run several rounds of each build before concluding.
- **Never write the Mac clipboard.** Pasteboard checks write the simulator's pasteboard only with `--pasteboard`, since a syncing host copies the write to the Mac.

## Gotchas

- In zsh, `log` is a builtin; call `/usr/bin/log` for the macOS tool.
- The screenshot flag is `--max-dim`.
- `button volume-*` cannot be checked from inside an app; the matrix saves a HUD screenshot for a person to look at.
- On tvOS Settings, the first `button down` only gives the list focus; the second moves it.
