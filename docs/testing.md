# Testing

## Unit tests

`swift test` covers pure logic: parsing, step lists, key maps, screen mapping, display listings, the setting catalog, JSON, accessibility element decoding and `LazyCapability`. None needs a simulator. Anything that touches a guest is checked by the matrix instead.

## The evaluation matrix

A command that returns `ok` may still have been dropped by the guest, so `Evaluation/matrix.py` checks effects, not replies.

```sh
swift build -c release
Evaluation/matrix.py <udid>                         # every section
Evaluation/matrix.py <udid> --only tree,tap         # some sections
Evaluation/matrix.py <udid> --pasteboard            # also write the pasteboard; needs the user's consent
Evaluation/matrix.py <udid> --timing --label base   # time common commands into .build/evaluation
SIMDRIVE=/path/to/other/simdrive Evaluation/matrix.py <udid> --timing --label other
```

- **iPhones and iPads** install the probe app and check the tree, light tree, taps, keys, typing, orientation with hit tests and taps in each landscape, buttons (home, lock and unlock, Siri, volume), edge swipes, `run`, settings as the app sees them, and the pasteboard.
- **Foldables** replace the orientation and button sections with every posture, checking that screenshots and trees follow the expected panel.
- **Apple TV** has no probe; it drives Settings and checks focus movement, hit tests and the expected `no-touchscreen`, `orientation-unsupported` and `setting-unsupported` errors.
- Settings are read at the start and restored when the run completes, and the run's daemon is stopped. An interrupted run restores nothing.

Results at v0.0.2: iPhone iOS 27 94/94, iOS 26 94/94, iOS 18 94/94, iOS 17 93/93, Duo 87/87, Apple TV 15/15.

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
| `TAP play` | The Play button fires |
| `VOLUME …` | The output volume changes, which the simulator never reports |

The log outlives runs. The matrix notes its line count before each action and matches only later lines.

`ORIENT` uses UIKit's numbering, so device `landscape-left` logs 3 and `landscape-right` 4: the reverse of CoreSimulator's `uiOrientation` for the same rotation.

## Keeping results trustworthy

- **Use your own simulators.** Create them with `xcrun simctl create`, and leave other simulators and their settings alone.
- **One matrix at a time per Mac when possible.** Several booted simulators slow each other: launches took up to 67 s with six booted, and `swipe scrolls` fails intermittently under load. Rerun a single failure alone before investigating it.
- **Wake the display first.** An idle iPhone simulator's display sleeps and drops rotations and the first touch; see [device behavior](device-behavior.md#iphone-and-ipad).
- **Clean up.** Stop the daemons you started (`simdrive <udid> stop`), return the Duo to its original posture and devices to portrait, and shut down the runtimes you booted.
- **Compare timings in rounds.** `tree` timings are bimodal, so one round's median can swing by 100 ms or more between identical builds. Run several rounds of each build before concluding.
- **Never write the Mac clipboard.** Pasteboard checks write the simulator's pasteboard only with `--pasteboard`, since a syncing host copies the write to the Mac.

## Gotchas

- In zsh, `log` is a builtin; call `/usr/bin/log` for the macOS tool.
- The screenshot flag is `--max-dim`.
- `button volume-*` cannot be checked from inside an app; the matrix saves a HUD screenshot for a person to look at.
- On tvOS Settings, the first `button down` only gives the list focus; the second moves it.
