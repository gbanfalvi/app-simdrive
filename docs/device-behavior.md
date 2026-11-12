# Device behavior

Observed on Xcode 27.0 and 27.2 with iPhone iOS 17.0, 18.3, 26.5 and 27.0, iPad iOS 26.5 and 27.0, iPhone Duo iOS 27.2 and Apple TV 4K simulators.

## Timing

- A fresh process spends 2–8 s resolving bindings before its first command; a warm daemon answers in tens of milliseconds.
- `simctl launch` returns 2.3–6 s before the app's scene is active. On a freshly booted simulator, with several others booted, apps took 20–67 s to come to the front.
- The accessibility server's frontmost pid matches the app's `SCENE active` to within about 0.3 s, which makes it a reliable launch signal.
- `tree` is bimodal: about 290 ms right after a launch or during animation, 25–150 ms otherwise.
- For about a minute after a simulator's first boot, the accessibility server answers slowly or not at all. A launching app answers with nothing, and any app occasionally does; simdrive retries three times, 0.5 s apart.
- The guest ignores touches during transitions and batches events while busy, such as right after launch.

## iPhone and iPad

- **Idle display sleep.** The iPhone simulator's display dims and sleeps when idle, as SpringBoard's idle timer allows. While asleep, rotations and the first touch are dropped, and screenshots freeze on the dimmed frame. Wake it with `button lock`, `button lock`, then `swipe 0.5 0.999 0.5 0.3 --edge bottom`.
- **Unlocking.** Without a passcode, the same `lock`, `lock`, edge swipe sequence returns to the app.
- **Going home.** A swipe up from the bottom goes home only with `--edge bottom`; the guest recognizes system gestures only for touches that start on an edge.
- **Volume.** `volume-up` and `volume-down` show the volume HUD, and DeviceHub's volume changes, but apps' `AVAudioSession.outputVolume` stays put. Check volume presses by screenshot.
- **Orientation.** The interface follows the device only when the foreground app supports that orientation, so it can differ from `orientation`'s reading. Face-up and face-down readings keep the last upright orientation for the interface.
- **Upside down.** No tested device reported an upside-down interface; Face ID iPhones do not support it.

## iPhone Duo

- Hardware model `v68`. Two panels: the cover panel, `simctl` role `primary`, and the inner panel, `primary-1`, display 3 on the tested device.
- Closed, the inner panel screenshots black; `simctl`'s display power does not unfold it. Commands default to the cover panel when closed and the inner panel otherwise.
- The cover panel accepts orientation changes, but its apps stay portrait.
- The inner panel's screenshots can be rotated relative to the panel while the device reads portrait. Mapping taps by device orientation alone flipped them 180° there, which is why simdrive reads the interface orientation per screen.
- The hinge animates toward the requested angle and settles near it, not on it.
- Ending an input connection within 500 ms of the last event lost the event on the Duo; 500 ms sufficed on single-display devices.

## Apple TV

- No digitizer and no orientation or pasteboard service. Remote buttons and the keyboard move and act on focus.
- `home` is the TV button and goes to HeadBoard, the home screen; `lock` opens Control Center; `menu` goes back.
- Settings has no focused element until the first `button down`.
- HeadBoard's tree may hold a single focusable element; test `tree` on Settings instead.
- `simctl ui` is unsupported, so `appearance`, `text-size` and `increase-contrast` read `unsupported`. The preference settings work.
- A quick relaunch of Settings can leave HeadBoard in front, which `launch` reports as `launch-not-frontmost`.
- While an app launches, `tree` can fail with `accessibility-translation` (no frame yet); retry after a second.

## Runtimes

- iOS 17 and 18 apps miss some accessibility changes unless the `com.apple.accessibility.cache.` notification follows the regular one.
- The expanded-status accessibility attribute exists from iOS 18.
- `show-borders` also drives `AccessibilitySettings.showBordersEnabled` from iOS 26.1.
- `non-blinking-cursor` needs iOS 18; `glass-tint` needs iOS 26.
- `prefer-cross-fade` has an effect only while `reduce-motion` is on.

## Hosts

- simdrive works with DeviceHub or NeoSimulator showing the device, or with neither.
- While simdrive holds the digitizer, clicks in DeviceHub do nothing; they work again 30 s after simdrive's last input, or after `stop`.
- DeviceHub syncs the guest's pasteboard with the Mac clipboard in both directions, so a simdrive pasteboard write replaces what the user copied.
