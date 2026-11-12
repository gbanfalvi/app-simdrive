---
name: simdrive
description: Drives a booted iOS or tvOS simulator headlessly with the simdrive CLI, sending hardware keys, typing, taps, swipes and edge gestures, Home/lock/volume and Apple TV Remote buttons, rotation, pasteboard reads and writes, and a foldable's (iPhone Duo) open, half-open or closed hinge, taking screenshots, reading the frontmost app's accessibility tree (labels, traits, VoiceOver elements, frames), and changing dark mode, text size, Liquid Glass tint and accessibility settings such as Reduce Motion or Bold Text. Use when an agent must interact with an app running in a simulator or Apple TV simulator, reproduce a UI bug, test keyboard navigation, Full Keyboard Access, tvOS focus, VoiceOver labels or Dynamic Type, or fold and unfold a Duo simulator.
---

# simdrive

Binary: `<simdrive>`, normally `<clone>/.build/release/simdrive`. If it is missing, run `swift build -c release` in the simdrive clone.

Each call prints one JSON line: `{"ok":true,"result":…}`, or `{"ok":false,"error":…,"code":…}` with exit status 1.

## Workflow

1. Pick the device: `simdrive list`. Use its UDID; `booted` works only when one simulator is booted.
2. Check it: `simdrive <udid> doctor` reports the displays, orientation, pasteboard, hinge and frontmost app.
3. Look: `simdrive <udid> screenshot /tmp/s.png`, then read the image. `simdrive <udid> tree` lists the app's elements with their labels, traits and tap points, which finds controls faster than reading pixels.
4. Act: tap an element's `point` from `tree`, pixels of the screenshot (`tap 120 340`) or fractions (`tap 0.5 0.25`). On an Apple TV, move focus with `button up|down|left|right` and activate with `button select`; `tree` marks the focused element `focused`.
5. Screenshot again to confirm. Wait about 1 s after launches and transitions, since the guest ignores input while they animate; on tvOS check that the app is frontmost after `launch`.

## Commands

```sh
S=<simdrive>
$S <udid> key tab                      # names: tab return escape delete space left right up down home end page-up page-down f1…f12, or one character
$S <udid> key f --mods cmd,shift --repeat 2
$S <udid> type "hello, world"          # US-layout characters only
$S <udid> tap 0.5 0.5
$S <udid> swipe 0.5 0.8 0.5 0.2 --duration 300
$S <udid> swipe 0.5 0.999 0.5 0.5 --edge bottom   # go home from an app
$S <udid> button home                  # home | lock | volume-up | volume-down | siri
$S <udid> button down --repeat 3       # Apple TV Remote: menu (Back) | select | play-pause | up | down | left | right | channel-up | channel-down; home is the TV button
$S <udid> button select --hold 1000    # long press
$S <udid> orientation landscape-left   # no argument reads it
$S <udid> pasteboard                   # items with their types and text
$S <udid> pasteboard "Grüße 東京"       # then: key v --mods cmd
$S <udid> posture closed               # closed | half | open; no argument reads the hinge angle
$S <udid> screenshot /tmp/s.png --max-dim 1024 --display inner
$S <udid> tree                         # frontmost app's accessibility hierarchy; voiceOver: true marks what VoiceOver stops on
$S <udid> tree 0.5 0.25                # the element at a point
$S <udid> setting                      # every setting's value
$S <udid> setting appearance dark      # also text-size accessibility-large, reduce-motion on, bold-text on, glass-tint 0.8…
$S <udid> launch com.example.app -someArgument
echo '["launch com.example.app", "wait 1500", "key tab", "screenshot /tmp/a.png"]' | $S <udid> run -
```

## Rules

- Fractions need a decimal point: `1 1` is a pixel, `1.0 1.0` is the bottom-right corner.
- Pixel coordinates refer to the most recent screenshot of that display. After rotating, take a new screenshot; `launch` and `button home` also reset it.
- Foldables: commands target the cover panel when closed and the inner panel otherwise; `--display cover|inner` overrides that.
- Writing the pasteboard replaces the user's Mac clipboard while DeviceHub or another syncing host runs, and reading it shows what the user copied. Write only for text `type` cannot enter, and tell the user.
- `tree` points and frames are fractions of the screen, ready for `tap`. Elements inside a `voiceOver` element are listed but VoiceOver skips them; custom views marked as accessibility elements hide their subviews entirely.
- Settings apply to the whole simulator and persist. Note each value before changing it (`setting <name>`), and set it back when done.
- The first call per device starts a daemon (2–8 s); later calls are fast. Until 30 s after the last input, the guest drops a person's clicks in DeviceHub or Simulator.app; `simdrive <udid> stop` releases the input services at once.
- Errors carry a `code`, such as `no-screenshot`, `stale-screenshot`, `unsupported-character`, `no-touchscreen`, `orientation-unsupported`, `pasteboard-unsupported`, `posture-unsupported`, `no-element`, `accessibility-timeout`, `setting-unsupported`, `ambiguous-device` or `step-failed`. Fix the cause the message names, then retry.

## Missing capabilities

When a task needs a simulator interaction simdrive lacks, such as a button, gesture, setting or sensor, add it to simdrive in its clone, following the clone's `AGENTS.md`, then update this skill. Do not work around it with AppleScript, Simulator.app menus or one-off `simctl` scripts.
