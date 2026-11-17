# Backlog

Work found by reviewing [NeoSimulator](https://github.com/lynnswap/NeoSimulator) at `d467c60` (2026-11-17), 50 commits past the `1dfc4af` that simdrive's guest input was ported from. Ordered by kind (fixes, then improvements to existing commands, then new features), and within each kind by cost.

## Conventions

- **Cost**: S is under half a day, M one to two days, L several days. Costs include tests and docs.
- **Paths**: `S:` is simdrive's `Sources/`, at `bdfde5b`. `N:` is NeoSimulator's `Sources/`, at `d467c60`. Line numbers drift; the symbols named next to them do not. Get the reference with:

  ```sh
  git clone https://github.com/lynnswap/NeoSimulator /tmp/NeoSimulator && git -C /tmp/NeoSimulator checkout d467c60
  ```

- **Every item** follows [AGENTS.md](../AGENTS.md): "Adding a capability" for structure, the README and skill for docs, and [docs/](../docs) for what was learned. Verify on simulators you created with `swift build -c release`, then `Evaluation/matrix.py <udid>`. Measure speed claims with `--timing --label <name>` before and after (`SIMDRIVE=<path>` runs another build).
- **Unverified** marks a claim taken from NeoSimulator's code or CoreSimulator's strings that nobody has run in simdrive.
- Tick an item when it is merged, and move what was learned into `docs/`.

## 1. Fixes

### - [x] F1. Keyboard input returns before the guest has its keys (S)

- **Problem:** `tap` and `button` wait on a barrier after sending, but `key` and `type` do not. A `run` step after typing, such as a screenshot, can start before the keys arrive, and a release right after typing relies on the 1000 ms drain alone.
- **Read:** `S:SimDriveNative/Input/GuestKeyboard.swift` (`press`, which sends without a barrier); `GuestTouchscreen.swift` and `GuestButtons.swift` for the barrier they use; `GuestConnection.flush()` in `S:SimDriveNative/Guest/SimulatorGuest.swift`.
- **Do:** after the last key of `press` and of `DeviceInputs.type`, `try await connection.flush()`, as the other inputs do. Flush once per `type` command, not once per key.
- **Test:** the matrix's `keys` section, which also checks `type`; `run` with `["type hello", "screenshot /tmp/t.png"]` shows the text.

### - [x] F2. Hit tests can return an element away from the point (S)

- **Problem:** web content can answer a hit test with an element whose frame does not contain the point (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:1093-1097`, comment on `accessibilityElement(at:)`). `tree <x> <y>` then reports the wrong element.
- **Read:** `S:SimDriveNative/Accessibility/SimulatorAccessibility.swift` (the hit test), `S:SimDriveCore/Accessibility/DeviceAccessibility.swift`.
- **Do:** when the returned frame does not contain the point, fail with `no-element`, or walk up its parents to one that does.
- **Test:** a `WKWebView` page in the probe app (add one), with `tree <x> <y>` on points inside and outside its elements. Add a unit test for the frame check.

### - [x] F3. Warn that iPhone Air and iPhone Duo report a failed boot (S, docs)

**Result:** observed on Air iOS 26.0 to 27.2 and Duo iOS 27.1 and 27.2, under Xcode 26.6 to 27.2. `bootstatus` exits 0 and returns early on second boots, so first commands time out; F9 and F7 cover that.

- **Problem:** these devices always end boot with status 3, data migration failed, though the guest runs (NeoSimulator #616, `N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:609-619`). `simctl bootstatus` reports a failure an agent may act on.
- **Do:** add to `docs/device-behavior.md` and the skill's rules: on these devices, a migration failure from `bootstatus` is expected. If simdrive ever waits on boot, through `SimDevice.bootStatus` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:259-263,517-528`), count status 3 on a booted device as started.

### - [x] F4. Find out whether typing needs Connect Hardware Keyboard (S, unverified)

**Result:** it does not. With the setting off, `keys` passed 34/34 on iPhone iOS 17.0, 18.3, 26.5, 27.0 and 27.2, and on Duo iOS 27.1. The iPad on iOS 27.2 passed it once full keyboard access was off (see F10), and `tv` passed 12/12 on tvOS 26.2. The Xcodes were 26.6 to 27.2. Recorded in `docs/device-behavior.md`.

- **Problem:** NeoSimulator refuses to type while its Connect Hardware Keyboard preference is off, "when the guest takes no hardware keyboard's keys" (`N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:704-719`). That preference is NeoSimulator's own (`N:NeoSimulatorKit/Simulator/Session/PreferenceStore.swift:44`), which it applies with `SimDevice setHardwareKeyboardEnabled:keyboardType:error:` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:369-370,1168-1173`). The keyboard type comes from `IndigoHIDGetKeyboardType()` in SimulatorKit (`N:NeoSimulatorPresentationAdapters/Simulator/SimulatorPresentationRuntime.swift:599,632`). simdrive creates its own main keyboard with `setSoftwareKeyboard(false)` and never calls this, and nobody has checked whether the setting gates simdrive's keys.
- **Do:**
  1. Call `setHardwareKeyboardEnabled:false` on a simulator you created, then `simdrive key a` into the probe's text field.
  2. If keys still arrive, close this item with a note in `docs/device-behavior.md`.
  3. If they don't, `GuestKeyboard.open` should enable it, through a new `SimulatorDevice` method in `SimDriveNative`, or fail with a new `hardware-keyboard-off` code.
- **Test:** the matrix's `keys` section, run after turning the setting off.

### - [x] F5. CoreDevice capabilities stay unavailable after an early boot (M)

**Result:** `CoreDeviceRemote.open` waits up to 5 s for the record to be listed and connected, then fails with `coredevice-not-ready`, which the next use retries. The bug did not reproduce. `pasteboard` or `posture`, called in a loop from `simctl boot` on iPhone iOS 17.0 and 27.0 and a Duo on iOS 27.1, first answered 12–40 s in, already connected, under both builds. Apple TV still reads `posture-unsupported`. The matrix's `misc,posture` and `tv` pass.

- **Problem:** right after boot, CoreDevice may not list the simulator yet, or may list it before it connects. A record that is not connected lists no features.
  - `CoreDeviceRemote.open` then returns nil (`S:SimDriveNative/CoreDevice/CoreDeviceRemote.swift:64-67`), or `supports()` returns false.
  - `CoreDevicePasteboard.open` (`S:SimDriveNative/DeviceControl/CoreDevicePasteboard.swift:25`) and `CoreDeviceHinge.open` (`S:SimDriveNative/DeviceControl/CoreDeviceHinge.swift:59`) return nil.
  - `LazyCapability` keeps that as unavailable for the daemon's life (`S:SimDriveCore/Session/LazyCapability.swift:31-36`), so `pasteboard` and `posture` fail with an "unsupported" code until `stop`.
- **Read:** NeoSimulator checks the connection before trusting features:
  - `isConnected()` compares `DeviceInfo.state` with `.connected` (`N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceRemoteScreenDevice.swift:212-224`).
  - It waits on `DeviceManager.deviceChanges` and `RemoteDevice.deviceInfoChanges` for a record that is missing or not yet connected (`N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceSimulatorRecord.swift:6-88`, `CoreDeviceInventoryChangeSource.swift:29`, `CoreDeviceRemoteScreenDevice.swift:228-240`).
- **Do:**
  1. Add `isConnected()` to `CoreDeviceRemote`, through `deviceInfo.state` and the `connected` enum case.
  2. In the CoreDevice drivers, return nil only when the record is connected and lacks the feature. Throw a new `core-device-not-ready` code when the record is missing or not connected, so `LazyCapability` retries on the next use.
  3. Optionally wait up to a few seconds for the connection first, by polling the record every 250 ms rather than binding the change streams.
- **Test:**
  - Boot a simulator you created and run `simdrive <udid> pasteboard` within a second of `simctl boot`. It should succeed, or fail with `core-device-not-ready` and succeed on retry, never `pasteboard-unsupported`.
  - Repeat with `posture` on a Duo.
  - Run the matrix's `misc` section, which reads the pasteboard.

### - [x] F6. A stalled CoreDevice blocks the daemon forever (M)

**Result:** `SharedInitialization` (`S:SimDriveNative/Support/SharedInitialization.swift`) runs one start, failing with `coredevice-timeout` after 30 s. Unit-tested; the matrix's `basics,misc` pass on iPhone iOS 27.0. A real stall was not reproduced.

- **Problem:** `CoreDeviceManager.shared()` awaits `awaitFullInitialization()` with no limit (`S:SimDriveNative/CoreDevice/CoreDeviceRemote.swift:9-27`). The daemon serves one request at a time, so a stalled CoreDevice service hangs every later command, keyboard and taps included. Concurrent callers also start separate initializations.
- **Read:**
  - NeoSimulator runs one shared initialization, which each caller waits on for at most 60 s: `SharedTask` (`N:NeoSimulatorDeviceIO/SharedTask.swift:3-57`), used in `N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceRemoteScreenDevice.swift:50-52`.
  - Its limits are in `N:NeoSimulatorDeviceIO/DeviceOperationPolicy.swift:57-81`: CoreDevice initialization and record 60 s, guest service 10 s, accessibility read 5 s, Web Inspector 5 s and 15 s to start.
- **Do:**
  1. Keep the initialization in one stored `Task`, so concurrent callers share it.
  2. Wait on it with `waitForCompletion(within:timeout:)` (`S:SimDriveNative/Support/WaitForCompletion.swift`), failing with a new `core-device-timeout` code after about 30 s.
  3. Forget a failed or timed-out task, so the next command tries again.
- **Test:** a unit test of the sharing and timeout logic, with a stub initializer. Then `doctor` and the matrix's `misc` section, to check nothing regresses.

### - [ ] F7. Accessibility reads take up to a minute to fail, and fail after first boot (M)

- **Problems:**
  - A read retries 3 times, 0.5 s apart, with a per-request limit (`S:SimDriveNative/Accessibility/SimulatorAccessibility.swift:31-41,124-176`), and makes two requests: the frontmost app, then its snapshot. Its worst case runs to tens of seconds; NeoSimulator bounds a whole read at 5 s (`N:NeoSimulatorDeviceIO/DeviceOperationPolicy.swift:71`, `N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:455-462`).
  - The first request after a boot starts the guest's accessibility server, which then names no app for some seconds (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:1084-1088`), hence the `accessibility-timeout` the README tells agents to retry.
  - `AccessibilityChannel.send` returns nil both for a timeout and for a completion without a response (`S:SimDriveNative/Simulator/SimulatorDevice.swift:166-176`). NeoSimulator reports a nil response as an unreachable service, and error 8 as an element that is gone (`N:NeoSimulatorDeviceIO/Simulator/SimulatorAccessibility.swift:131-133`, `CoreSimulator.swift:482-486`).
- **Do:**
  1. Give each `tree` one deadline across all of its requests and retries, about 8 s.
  2. When a session opens, send one frontmost-app request in the background, without waiting, to start the guest's accessibility server early.
  3. Split the nil result into "no answer in time" (`accessibility-timeout`) and "unreachable" (new `accessibility-unavailable`). Map error 8 to `no-element`.
- **Test:** on a simulator just booted from shutdown, `tree` succeeds on the first call more often than before; record the result in `docs/device-behavior.md`. Add unit tests for the deadline arithmetic if it is factored out, and run the matrix's `tree` section.

### - [ ] F8. The daemon keeps its session across a reboot (M)

- **Problem:** the daemon creates one `DeviceSession` and keeps it (`S:SimDriveCore/Daemon/DaemonServer.swift`, around lines 100-110). `isBooted` is checked only when the session opens (`S:SimDriveCore/Session/DeviceSession.swift:46`). After a reboot, its guest connections, CoreDevice record, accessibility bridge and screen records point at the old boot, and the screen records are only reset through `ScreenStore`'s boot date. NeoSimulator advances a generation on each inventory change (`N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceSimulatorRecord.swift:176-184`).
- **Do:**
  1. Before each request, compare `SimulatorDevice.lastBootedAt` and `isBooted` with the values the session opened with.
  2. On a change, close the session, releasing its inputs, and open a new one.
  3. A shut-down device fails with the existing not-booted error, and the daemon exits.
- **Test:** for this simulator, start the daemon with `tap`, then `simctl shutdown` and `simctl boot`, then `tap` again. The second `tap` works, and the `doctor` from before the reboot no longer answers.

### - [x] F9. A slow orientation service fails `screenshot` and `tree` after boot (S)

**Result:** `screenshot`, taps and calibration treat a failed device orientation read as unknown; `orientation` and `doctor` still report it. The interface orientation now comes from the framebuffer (I7), so taps keep mapping right. Not reproduced: on four boots of an Air iOS 27.2 under Xcode 27.2, `screenshot` succeeded 9–12 s after `bootstatus`, cold daemon included; `tree` failed twice with `accessibility-timeout` (F7).

- **Problem:** found testing F3. Right after `bootstatus` returned on an iPhone Air iOS 27.2 under Xcode 27.2, `tree` and `screenshot` failed with `guest-service-timeout` naming `com.apple.coredevice.feature.remote.devicecontrol.orientation`, after 11–36 s. A Duo iOS 27.1 failed `tree` the same way. A screenshot needs the orientation only to record it, and `Screens.deviceOrientation()` (`S:SimDriveCore/Screens/Screens.swift:83-86`) throws instead of falling back. Its callers fall back to portrait only for nil.
- **Do:** in `Screens`, prefer the interface orientation CoreSimulator reports (`interfaceOrientation(of:)`, same file) and read the guest's only when that is nil. Treat a guest read that fails as nil, so `screenshot` and `tree` degrade to portrait instead of failing. `orientation` itself keeps failing.
- **Test:** boot an Air you created, and within a second of `simctl bootstatus -b` returning run `screenshot` and `tree` under Xcode 27.2. Neither fails with `guest-service-timeout`. Then run the matrix's `orientation` and `tap` sections.

### - [x] F10. The matrix assumes an iPhone's layout and state (S)

**Result:** `tree,tap,keys` pass 38/38 on iPad Air iOS 27.2, with full keyboard access on, and on iPhone iOS 27.0.

- **Problem:** found testing F4. On iPad Air iOS 27.2, with the hardware keyboard on or off, three checks fail and simdrive is not at fault:
  - `tree offscreen rows` finds 0/12 offscreen, because the tall screen shows every row.
  - `tree hit test --no-daemon` hits a gap at 0.5, 0.5, between the probe's "Two" and "Glass" elements, and gets `no-element`.
  - `type` reads `xxxhello, world`: the field keeps focus, so the earlier `key x --repeat 3` check types into it.
  - The matrix also leaves full keyboard access as it finds it. While on, it fails `key left` and `key tab`.
- **Read:** `Evaluation/matrix.py`: `tree_checks` (around line 213-224), `key_checks` and `clear_field` (around 338-363).
- **Do:**
  1. Make the probe's list longer than an iPad's screen.
  2. Hit-test `Play`'s point with `--no-daemon`.
  3. Call `clear_field()` after tapping the field, before `type`.
  4. Turn `full-keyboard-access` off before the `keys` section, and restore it after.
- **Test:** the matrix's `tree` and `keys` sections pass on an iPad and an iPhone you created, with full keyboard access on beforehand.

### - [x] F11. Taps on the Duo's inner panel land 0.046 right (S)

**Result:** taps were right; `tree` was wrong, in every posture. A status strip takes the right of both Duo panels, and `tree` measured fractions against the app's frame, so its points sat 1.21× too far right on the cover panel and 1.09× on the inner one. `tree` now sizes the screen from the screenshot and the device type's scale, and turns the inner panel's app frame to fit the interface. The probe logs fractions of its window, which the matrix now converts with the app's frame. `tree` and `tap` pass on the Duo closed, open and half-open, and on an iPhone, iPad and Apple TV.

- **Problem:** found testing I7. On a Duo iOS 27.1, open, the matrix's `tap [at 0.5,0.131]` fails: the probe logs `TOUCH began 0.546 0.131 interface=4`, outside the check's 0.03 tolerance. Play is wide enough that `TAP play` still fires. `tap --no-daemon` passes only because it checks `TAP play` alone. The build before I7 fails the same way. The screen record is 2853x2007, `landscapeLeft`. Either the mapping is off, or the probe's window does not span the panel.
- **Do:** log the probe window's frame against the panel's points; fix the mapping in `Screens` if the window spans the panel, else make the probe report fractions of the screen.
- **Test:** the matrix's `tap` section passes on the Duo, open and half-open, and on an iPhone.

### - [x] F12. `run --logs` gives a tap's entries to the next step on the Duo (S)

**Result:** reproduced on a Duo iOS 27.2, where the probe logged `TAP play` 100 ms into the next step. Each step's span now starts and ends 250 ms late, except the first start. The matrix's `logs` section passes 34/34 on the Duo and an iPhone 18 Pro, both iOS 27.2.

- **Problem:** found testing F11. On a Duo iOS 27.1, the matrix's `run --logs attributes the tap` fails every time, before and after I7: in `["tap …", "logs --until \"TAP play error\"", "wait 100"]` the tap step gets no entries, and the `logs` step reads `TAP play` about 80 ms in. The probe logs after `tap` returns, so per-step attribution by start time misses it.
- **Do:** check on an iPhone whether it passes there by luck; then attribute entries up to a short grace after each step ends, or let the matrix accept the entry in either step.
- **Test:** the matrix's `logs` section on the Duo and an iPhone.

### - [x] F13. Split apps' origin for apps built with Xcode 27.0 (S)

**Result:** the origins hold for both SDKs, on Duo iOS 27.1 and 27.2. A probe relinked to the 27.0 SDK with `vtool` leaves the status strip out of its window, 0.917 wide in full and 0.409 in the right half, and reports that window as its own frame, so `split` read it as full and failed with `split-dropped`. Half or full is now measured against the screenshot's width. No strip showed on the left of a left-half app. `tree` points tap Play and hit-test to it in every layout for both builds; the matrix's `tree` and `tap` pass on iOS 27.2.

- **Problem:** `tree` places a split app's elements from fixed origins, 0 and 0.5068, measured on Settings and the probe (Xcode 27.2). The user reports that apps built with Xcode 27.0 use the Duo's status strip differently from 27.1 and later builds, and that the strip can show on the left of a left-half app, which would move that app's origin.
- **Do:** build the probe with Xcode 27.0; in each half, tap two points and fit its logged window fractions to the origin, as was done for 27.2. Derive the origin per build if they differ.
- **Test:** the matrix's `tree` and `tap` sections, with the probe split left and right, under both builds.

## 2. Improvements to existing commands

### - [ ] I1. Type without per-key delays (S)

- **Problem:** `type` holds each key 40 ms (`GuestKeyboard.keyHold`, `S:SimDriveNative/Input/GuestKeyboard.swift:6,33`) and waits 40 ms after it (`DeviceInputs.Timing.keyGap`, `S:SimDriveCore/Input/DeviceInputs.swift:10,50`). It also sends a Shift change before and after every shifted character. That is at least 80 ms a character, about 8 s for 100. NeoSimulator sends key-down then key-up with no delay, sends a modifier change only when Shift actually changes, and sends one release at the end (`N:NeoSimulatorPresentationAdapters/Native/NativeDeviceKeyboard.swift:154-175`).
- **Do:**
  1. Add a `type(_ strokes:)` to `GuestKeyboard` that tracks the current Shift state across keys.
  2. Drop the hold and the gap, and flush once at the end (F1).
  3. Keep `press`'s hold for `key`, where it costs one key.
- **Test:**
  - The matrix's `keys` section (`key_checks` in `Evaluation/matrix.py`), extended with doubled letters (`"aabb"`), mixed case, and a long string (200 characters). The probe's `TEXT` lines must match exactly.
  - Time `type` with `--timing` before and after.
  - Some guests may merge same-key repeats without a gap. If doubled letters drop, keep a minimal gap, such as 5 ms, between identical keys only.

### - [ ] I2. Drop the 400 ms wait when opening touch and buttons (S)

- **Problem:** `GuestTouchscreen.open` and `GuestButtons.open` wait `GuestInputTiming.settle`, 400 ms (`S:SimDriveNative/Input/GuestTouchscreen.swift:46`, `GuestButtons.swift:48`). They only open an XPC connection, though, and create no guest service, which is what the wait covers for the keyboard. NeoSimulator posts touches and buttons as soon as it connects (`N:NeoSimulatorPresentationAdapters/Native/GuestScreenInput.swift:18-33,125-149`). The wait costs 400 ms on the first input after every 30 s idle release.
- **Do:** remove the wait from those two, and keep it in `GuestKeyboard.open`, after `createService`.
- **Test:**
  - `simdrive <udid> stop`, then a single `tap` on the probe's Play button: the probe logs `TAP play`. Repeat 20 times.
  - The same with `button home` and a screenshot.
  - The full matrix on an iPhone and on the Duo, since the Duo needed longer waits before.
  - Time it with `--timing`.

### - [ ] I3. Narrow simdrive's native symbol lookups (S)

- **Problem:** `xpc_endpoint_create_mach_port_4sim` and `xpc_connection_enable_sim2host_4sim` are resolved in automatic scope (`S:SimDriveNative/Guest/SimulatorGuest.swift:21-24`), which searches every loaded image. NeoSimulator #574 limits them to libxpc with `in: ImageSelector.installName("/usr/lib/system/libxpc.dylib"), loading: .loadedOnly` (`N:NeoSimulatorDeviceIO/CoreDevice/SimulatorGuestHID.swift:21-25`). `CoreDeviceManager` also makes seven `resolve` calls outside any `prepare` batch (`S:SimDriveNative/CoreDevice/CoreDeviceRemote.swift:23-24,33-39`).
- **Do:** scope the two xpc lookups to libxpc. Move the resolves into one `runtime.prepare { … }` where they share a batch.
- **Test:** time `doctor --no-daemon` and `tap 0.5 0.5 --no-daemon` with `--timing`, several rounds, before and after. Combine with I5 if both are done together.

### - [ ] I4. Change appearance, text size and contrast in process (S)

- **Problem:** `setting appearance|text-size|increase-contrast` spawns `simctl ui` to read and to write (`S:SimDriveCore/Settings/DeviceSettings.swift:38,107`). Each spawn costs hundreds of milliseconds, and listing all settings spawns three.
- **Read:** `SimDevice` has `setUIInterfaceStyle:error:` (Int), `setContentSizeCategory:error:` (Int, 1-12) and `setIncreaseContrastEnabled:error:` (Bool), with getters `currentUIInterfaceStyle`, `currentContentSizeCategory` and `currentIncreaseContrastMode` (0 unknown, 1 off, 2 on). See `N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:316-343,986-1000`. NeoSimulator's content-size numbering is in its `DeviceSettings` types (`N:NeoSimulatorKit/Devices/DeviceSettings.swift`).
- **Do:**
  1. Add these methods to `S:SimDriveNative/Simulator/SimulatorDevice.swift`, as `postDarwinNotification` is done: `NSSelectorFromString` plus `method(for:)` cast to `@convention(c)`, or ABIBridge.
  2. Map them in `SettingCatalog` in place of the `simctl ui` options.
  3. Keep `unsupported` on tvOS by checking `responds(to:)` or catching the error.
- **Test:** the matrix's `settings` section on an iPhone, iOS 17 and 27, where the probe logs the trait-collection change, and on Apple TV, where the settings stay `unsupported`. Time `setting` with no arguments before and after.

### - [ ] I5. Upgrade ABIBridge from 0.19.1 to 0.20.4 (M)

- **Why:** `docs/design-decisions.md` pins the ABIBridge version NeoSimulator uses, which is now 0.20.4 (`/tmp/NeoSimulator/Package.swift`). Relevant changes:
  - Symbol tables are kept for 1 s after a batch instead of being rebuilt on every lookup (0.20.2).
  - Path and framework selectors with `.loadedOnly` filter by file name before resolving symlinks, and cache the match (0.20.1, 0.20.3, 0.20.4).
  - The export-trie walk is faster.
  - Both lookup changes target simdrive's 2-8 s cold start: `KeyboardBindings` makes four `.path` lookups (`S:SimDriveNative/Input/KeyboardBindings.swift:48-52`). CoreDevice's own `awaitFullInitialization` is unaffected.
- **API changes:**
  - `ABIRuntime` and `NativeSwiftType` became `Sendable` final classes, not actors, so some `await`s may become unnecessary warnings.
  - The `in: NativeImage` overloads are gone; use `.image(…)`.
  - Hook error types were unified, which doesn't affect simdrive.
  - Methods with typed throws must declare `throws(Failure)`. simdrive already does (`S:SimDriveNative/DeviceControl/CoreDeviceHinge.swift`, `CoreDevicePasteboard.swift`).
  - Read the call-site changes in NeoSimulator's bump commits: `git -C /tmp/NeoSimulator show 23f7d07 fca2894 02d0c91 a1c3c77 bacc188`.
- **Do:**
  1. Change the pin in `Package.swift`, build, and fix call sites.
  2. Update the version named in `docs/design-decisions.md` ("Port NeoSimulator onto ABIBridge") and `docs/architecture.md`.
- **Test:**
  - `swift test`, then the full matrix on an iPhone, a Duo and an Apple TV.
  - `--timing` against the old build (`SIMDRIVE=<old build>`), several rounds.
  - Record the cold-start numbers in `docs/device-behavior.md`.

### - [ ] I6. Detect a sleeping display, and wake it (M)

- **Problem:** an idle iPhone simulator's display dims and sleeps. Rotations and the first touch are then dropped, and screenshots show the dimmed frame. The workaround is `lock`, `lock`, edge swipe (`docs/device-behavior.md`, "Idle display sleep"; `docs/open-questions.md`, "Display sleep"). NeoSimulator does not prevent sleep, but it detects it:
  - **Backlight:** each screen's `screenProperties.backlight.state` is 2 when on, 1 when dimmed and 0 when off (`N:NeoSimulatorPresentationAdapters/Simulator/SimulatorConnection.swift:236-247`, `N:NeoSimulatorKit/Simulator/Session/DeviceSessionDisplay.swift:26`).
  - **Lock:** `SimDevice darwinNotificationGetState:name:error:` on `com.apple.springboard.lockstate` reads 1 when locked (`N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:1006,1048-1050`, `N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:326`).
  - Its `lock()` presses Lock until that state reads 1, for up to 5 s (`DeviceSession.swift:1015-1046`).
- **Do:**
  1. Read `backlight.state` in `S:SimDriveNative/Simulator/ScreenAdapter.swift`, next to `uiOrientation`, and the lock state through a new `SimulatorDevice.darwinNotificationState(_:)`.
  2. Report both in `doctor`.
  3. Before `tap`, `swipe` and `orientation` on an iPhone or iPad whose backlight is below 2, wake it: press `lock`, wait until the backlight reads 2, and add the edge swipe only if the lock state reads 1. Report `"woke": true` in the result.
  4. Make the wake opt-out with a `--no-wake` flag, if waking surprises someone.
- **Test:**
  - Leave a simulator you created idle until it dims (SpringBoard's idle timer), then `tap` the probe's Play button. The probe logs `TAP play`, and the result says it woke.
  - Run the matrix's `orientation` section after an idle period.
  - Add the observed timings to `docs/device-behavior.md`, and close the open question.

### - [x] I7. Take screenshots in process (M, unverified)

**Result:** simdrive copies the screen's framebuffer surface instead of calling the capture service, which takes 350 ms. Release `--timing`: `screenshot` 763 to 337 ms on iPhone iOS 27.0, 1755 to 82 ms on iPad Air iOS 27.2; `tree after launch`, which calibrates, 836 to 427 and 1812 to 181 ms. The matrix's `basics`, `orientation`, `tap` and `posture` sections pass on iPhones iOS 26.5 and 27.0, the iPad, a Duo and an Apple TV, except F11, which predates this. Images match `simctl`'s except the Dynamic Island and the Duo's camera hole and corner (`docs/private-apis.md`). The timing case `tree 0.5 0.5` hits empty space on the iPad.

- **Problem:** every screenshot spawns `simctl io screenshot` (`S:SimDriveCore/Screens/Screenshots.swift`). NeoSimulator does the same (`N:NeoSimulatorKit/Simulator/Management/DeviceToolRunner.swift:111-114`), but `simctl` itself calls a CoreSimulator capture service. Its strings include `com.apple.display.captureservice`, `SimScreenCaptureService` and "Capture port descriptor does not conform to SimScreenCaptureService".
- **Read:**
  - `SimScreenCaptureService` has `captureScreenshotFromScreen:maskPolicy:imageType:outputFile:completionQueue:completionHandler:`. Check with `strings /Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Frameworks/CoreSimDeviceIO.framework/CoreSimDeviceIO`.
  - The port is found like the framebuffer port, in `SimDevice.io.ioPorts` by `portIdentifier` (`S:SimDriveNative/Simulator/ScreenAdapter.swift:11,20`), and its `descriptor` is the service.
  - Another route is the screen's IOSurface: the `SimScreen` proxies from `enumerateScreensWithCompletionQueue:` answer `registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:`. NeoSimulator's thumbnails read SimulatorKit's `SimDeviceScreen.maskedSurface` and `unmaskedSurface` instead (`N:NeoSimulatorPresentationAdapters/Simulator/SimulatorScreenThumbnail.swift:202-259`). They rotate by `uiOrientation`, and need `powerState == 1` (`:230-234`).
- **Do:**
  1. Find the argument values with the Objective-C runtime (`docs/private-apis.md`, "Finding more"): mask policy, image type (PNG), and which screen object to pass.
  2. Add a `SimDriveNative` driver, `SimulatorCapture`, with `capture(display:to:)`, and use it in `Screenshots`.
  3. Fall back to `simctl` when the port is missing or the call fails.
  4. Keep the PNG signature check NeoSimulator does (`N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:2057-2077`).
- **Test:**
  - The matrix's `basics`, `orientation` and `posture` sections: images must match `simctl`'s, including rotation and the Duo's two panels.
  - Time `screenshot` with `--timing`.
  - Document the service in `docs/private-apis.md`, and close the "Faster screenshots" open question.
- **Later:** the IOSurface seed (`IOSurfaceGetSeed`, `SimulatorScreenThumbnail.swift:21`) changes with each frame. That allows a `wait-still` command, which returns once the screen stops changing and could replace fixed `wait`s after transitions.

### - [ ] I8. List elements an alert covers, and read apps other than the frontmost (M)

- **Problem:** `tree` reads only the frontmost app, as the translator presents it. When an alert or sheet is up, the elements behind it are missing, and when SpringBoard shows system UI, the app's tree can't be read.
- **Read:**
  - NeoSimulator sets the request's client type to 2, which on iOS 27.2 also returns covered elements; types 0 and 1 return only what is on screen (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:446-449,471`).
  - Request type 1, with `["pid": Int32]`, reads any process (`N:NeoSimulatorDeviceIO/Simulator/SimulatorAccessibility.swift:94-101,161-167`).
  - simdrive's requests go through `AccessibilityBridge.requestSender` (`S:SimDriveNative/Accessibility/SimulatorAccessibility.swift`, around 205-215), where `request.setValue(2, forKey: "clientType")` would go.
- **Do:**
  1. Add `tree --covered`, which sets client type 2. Covered elements get `covered: true` when their frame is under an alert; compare against the frontmost read.
  2. Add `tree --app <bundle-id>`, which reads that app's process through the pid from `simctl spawn launchctl list` or the log store.
  3. Test first whether client type 2 works with the snapshot attribute.
- **Test:** the probe app needs an alert (add a button that presents one). Check `tree` and `tree --covered` with the alert up. Add unit tests for the parsing.

### - [ ] I9. Say whether an error is worth retrying, and cancel abandoned requests (M)

- **Problem:** errors carry a `code`, but an agent must know from the skill which codes are safe to retry. A client that disconnects, for example after a Ctrl-C or a timeout, leaves its request running in the daemon and blocks the next one.
- **Read:**
  - `IdentifiedFailure` categorizes errors as temporary, unavailable or io (`N:NeoSimulatorDeviceIO/IdentifiedFailure.swift:4-12`).
  - `SimulatorDeviceChannel` tells "not sent", "outcome unknown" and "no answer" apart after a deadline (`N:NeoSimulatorDeviceIO/SimulatorDeviceChannel.swift:66-111`).
  - NeoSimulator's control socket cancels a request's task when its client disconnects (`N:NeoSimulatorManager/Control/ControlSocket.swift:171-179`).
- **Do:**
  1. Add `"retry": true|false` to error JSON, from a category on each `ErrorCode` (`S:SimDriveNative/Support/SimDriveError.swift`).
  2. In `DaemonServer`, cancel the request's `Task` when the client's socket closes. Inputs must still release what they hold; `pause` already ignores cancellation.
- **Test:** unit tests for the category table. Run `logs --until never --timeout 60000` inside `run`, kill the client, and check that the next command answers at once.

### - [ ] I10. Apply settings through the guest's own setting actions (L, unverified)

- **Problem:** most settings are a `defaults write` plus Darwin notifications. They miss side effects that the Settings app applies, and need a probe check on each runtime. CoreDevice declares guest actions that apply a setting as Settings does, and read it back.
- **Read:**
  - `N:NeoSimulatorDeviceIO/CoreDevice/GuestSettingsActions.swift:120-187` sends each action straight to the guest's Mach service, with no CoreDevice record. It finds the feature from `CoreDeviceUtilities.<Name>ActionDeclaration.executionLocation`.
  - The XPC message carries `CoreDevice.actionIdentifier`, `CoreDevice.deviceIdentifier`, `CoreDevice.invocationIdentifier`, `CoreDevice.CoreDeviceDDIProtocolVersion` = 1, `coreDeviceVersion`, and input encoded with `Mercury.XPCObjectEncoder`.
  - The actions are `Get`/`Set` + `ReduceMotion`, `ShowBorders`, `ReduceTransparency`, `VoiceOver`, `ColorFilter`, `LiquidGlassConfiguration` and `DeviceLookAndFeel` (`N:NeoSimulatorKit/Devices/SimulatorGuestSettings.swift:89-179`).
  - Look-and-feel and Liquid Glass answer error 21046 and 21035 on iOS 26; color filters change only from iOS 27 (`GuestSettingsActions.swift:31-58`, `SimulatorGuestSettings.swift:43-58`).
  - Feature identifiers include `com.apple.coredevice.feature.voiceover`, `customizeappearancesettings`, `customizeliquidglass` and `customizeuistyle`.
  - The guest connection is the one simdrive's `GuestOrientation` uses (`S:SimDriveNative/DeviceControl/GuestOrientation.swift`), and its message encoding is in `S:SimDriveNative/Guest/GuestMessageCodec.swift`.
- **Do:**
  1. Add a `GuestSettingActions` driver in `SimDriveNative/DeviceControl/`, with `value(of:)` and `set(_:to:)` for each action.
  2. Move the settings whose actions exist to it: `reduce-motion`, `show-borders` and `reduce-transparency`. Keep `defaults` for the rest.
  3. Add a row kind to `SettingCatalog` for action-backed settings.
- **Test:** the matrix's `settings` section on iOS 17, 18, 26 and 27, where the probe app logs each change. Document the actions in `docs/private-apis.md`.
- **Unlocks:** N20.

## 3. New features

Each new command needs a `Command` case, parsing, usage text, results JSON, an error code where it can fail, parser tests, a README row and a skill line, per AGENTS.md's "Adding a capability".

### - [ ] N1. `openurl <url>`: open a URL or deep link (S)

- **Why:** agents test deep links and universal links, and today must leave simdrive to do it.
- **Do:**
  - `simctl openurl <udid> <url>` through `DeveloperTools`, as `launch` does.
  - Wait for the frontmost app to change, reusing `launch`'s frontmost poll, and return `{"url", "app": {"name", "pid"}}`.
- **Test:** the probe registers a URL scheme (add `CFBundleURLTypes` to `Evaluation/Probe/Info.plist`) and logs `URL <url>` from `scene(_:openURLContexts:)`. Add a matrix check.

### - [ ] N2. `install <path.app|path.ipa>` and `uninstall <bundle-id>` (S)

- **Do:**
  - `simctl install <udid> <app>`. For an `.ipa`, unzip it to a temporary directory and install `Payload/*.app` (NeoSimulator uses `ditto -x -k`, `N:NeoSimulatorKit/Simulator/Import/InstallableApplication.swift:16-46`).
  - `simctl uninstall`.
  - Return the bundle ID, read from the app's `Info.plist`.
- **Test:** install and uninstall the probe app in the matrix's setup, replacing `build-probe.sh`'s own install.

### - [ ] N3. `shake` (S)

- **Do:** `SimDevice postDarwinNotification` of `com.apple.UIKit.SimulatorShake` (`N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:856`). simdrive already posts notifications (`S:SimDriveNative/Simulator/SimulatorDevice.swift:96`). Put the name in a `SimDriveCore` constant, used by a `DeviceSession` method.
- **Test:** the probe logs `SHAKE` from `motionEnded(_:with:)` on its view controller; add a matrix check.

### - [ ] N4. `memory-warning` (S)

- **Do:** write an empty file at `SimDevice.memoryWarningFilePath`, as `SimDevice.simulateMemoryWarning` does (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:164-165,1038-1044`; `N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:1301`). Add `memoryWarningFilePath` to `SimulatorDevice`.
- **Test:** the probe logs `MEMORY` from `UIApplication.didReceiveMemoryWarningNotification`; add a matrix check.

### - [ ] N5. `biometrics enroll|unenroll|match|fail` (S)

- **Do:**
  - **Match and fail:** post `com.apple.BiometricKit_Sim.<source>.match` or `.nomatch`. The source is `pearl` (Face ID), `fingerTouch` (Touch ID) or `oyster` (Optic ID) (`N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:957-978`).
  - **Enrollment:** set the state of `com.apple.BiometricKit.enrollmentChanged` with `darwinNotificationSetState:name:error:` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:330`), then post it. See NeoSimulator's enrollment code next to line 957 for the state values.
  - Choose the source from the device type, or with `--type`.
- **Test:** the probe adds a "Biometrics" button that calls `LAContext.evaluatePolicy` and logs `BIO ok|fail`. Check enroll, then match, then fail.

### - [ ] N6. `slow-animations on|off` (S)

- **Do:** set the state of `com.apple.UIKit.SimulatorSlowMotionAnimationState` and post it (`N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:1142-1157`). Check that the runtime supports it first (`com.apple.UIKit.SimulatorSlowMotionStateful`, `:82-84`). This could be a `setting` row (`slow-animations`, toggle) instead of a command.
- **Test:** the probe logs `UIView.inheritedAnimationDuration`, or the layer's speed, of an animation it runs. Simplest: time a known 0.3 s animation with two screenshots.

### - [ ] N7. Core Animation debug colors (S)

- **Do:**
  - Settings rows `color-blended-layers` (option 2), `color-copied-images` (1), `color-misaligned-images` (14) and `color-offscreen-rendered` (17), through `SimDevice setCADebugOption:enabled:` and `getCADebugOption:` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:348-352,1078-1083`; `N:NeoSimulatorKit/Simulator/Input/HIDInput.swift:83-99`).
  - Errors are not reported, so read the value back.
  - This needs a setting kind for SimDevice-backed values in `SettingCatalog`.
- **Test:** toggle each option and read it back; a screenshot of the probe shows the tint. Add a matrix check of the read-back.

### - [ ] N8. More buttons (S)

- **Do:** add to `HardwareButton` (`S:SimDriveNative/Input/GuestButtons.swift`) with a usage page per button, since `usagePage` is fixed at `0x0C` today (`:6`). Usages are from `N:NeoSimulatorKit/Simulator/Input/HIDInput.swift:13-30,64`:

  | Button | Page | Usage | Note |
  | --- | --- | --- | --- |
  | `keyboard` | 0x0C | 0xB8 | Shows or hides the software keyboard, which simdrive's hardware keyboard hides |
  | `side` | 0x0C | 0x95 | |
  | `apple-pay` | 0x0C | 0x1BA | |
  | `screenshot` | 0x0C | 0x65 | The guest's own screenshot |
  | `action` | 0x0B | 0x2D | iPhone Action button; held 500 ms (`N:NeoSimulatorUI/Commands/DeviceCommand.swift:200-203`) |

  The App Switcher is `home` twice, 150 ms apart (`DeviceCommand.swift:213`): add `button app-switcher`, or document `button home --repeat 2`.
- **Test:** `keyboard` toggles the probe's software keyboard, visible in a screenshot; `app-switcher` shows the switcher. Add matrix checks.

### - [ ] N9. `pinch` and `rotate` gestures (S)

- **Do:** `IndigoDigitizerEvent(pointOne:pointTwo:eventType:edge:target:)` takes a second finger. simdrive passes nil (`S:SimDriveNative/Guest/GuestMessageCodec.swift:119-123`), and NeoSimulator passes it (`N:NeoSimulatorDeviceIO/CoreDevice/SimulatorGuestHID.swift:250-254`).
  - Add `GuestTouchscreen.drag(_ fingers: [(from, to)])`.
  - Add commands `pinch <x> <y> <scale> [--duration ms]` and `rotate <x> <y> <degrees>`, which compute both fingers around a center.
  - Both fingers start and end together.
- **Test:** the probe adds a `UIPinchGestureRecognizer` and a `UIRotationGestureRecognizer` that log `PINCH scale=` and `ROTATE angle=`; add matrix checks.

### - [ ] N10. `location set <lat> <lon>|run <scenario>|clear|list` (S)

- **Do:** `simctl location <udid> set <lat>,<lon>`, `run <scenario>` and `clear`, as NeoSimulator does (`N:NeoSimulatorKit/Devices/DeviceSettingsBackend.swift:333-345`). Use `availableLocationScenarios` on `SimDevice` for `list` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:357-367,1140-1166`), or `simctl location list` if it exists.
- **Test:** the probe adds `CLLocationManager` updates (with `NSLocationWhenInUseUsageDescription`, after granting with N11's `privacy`) and logs `LOCATION lat lon`.

### - [ ] N11. `push`, `privacy` and `status-bar` wrappers (S)

NeoSimulator has none of these; `simctl` covers them.

- **Commands:**
  - `push <bundle-id> <payload.json|->` runs `simctl push`.
  - `privacy <grant|revoke|reset> <service> <bundle-id>` runs `simctl privacy`.
  - `status-bar override [--time 9:41] [--battery 100] …` and `status-bar clear` run `simctl status_bar`.
- **Why:** agents need permissions granted without tapping alerts, deterministic status bars for screenshots, and push handling.
- **Test:** the probe logs `PUSH <aps.alert>` from `userNotificationCenter(_:willPresent:)`. A privacy grant makes the probe's location request skip its alert. A status-bar override shows in a screenshot.

### - [ ] N12. `keyboard-language <code>` (S)

- **Do:**
  - Call `SimDevice setKeyboardLanguage:error:` with a code such as `ja` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:372-373,1175-1179`).
  - Each call makes the guest reload its keyboards, which delays the switch by several keystrokes, so return after it settles (`N:NeoSimulatorUI/Display/DeviceWindowController.swift:993-1003`).
  - Typing in that language still needs a key map for its layout; prefer N15's set-value for non-US text.
  - Also add the JIS 英数 and かな keys to `KeyMap` as `eisu` and `kana` (`kVK_JIS_Eisu`, `kVK_JIS_Kana`; `N:NeoSimulatorPresentationAdapters/Native/NativeDeviceKeyboard.swift:285-294`).
- **Test:** after `keyboard-language ja`, a screenshot of the software keyboard (N8's `button keyboard`) shows the Japanese keyboard.

### - [ ] N13. `orientation left|right`: relative rotation (S)

- **Do:** send the orientation request's `rotate(left:)` case (`N:NeoSimulatorDeviceIO/CoreDevice/SimulatorGuestHID.swift:386-389,414`) from `S:SimDriveNative/DeviceControl/GuestOrientation.swift`. NeoSimulator allows the request 30 s, where simdrive allows 10 s (`SimulatorGuestHID.swift:403`); keep 10 s unless it times out.
- **Test:** the matrix's `orientation` section; the probe logs `ORIENT`.

### - [ ] N14. `icloud-sync` (S)

- **Do:** `SimDevice triggerCloudSyncWithCompletionQueue:completionHandler:`, waiting up to 300 s as NeoSimulator does (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:344-347,1012-1029`; `DeviceOperationPolicy.swift:78`).
- **Test:** returns without error on a simulator signed in to iCloud; fails with a clear code otherwise. Manual check only.

### - [ ] N15. `press` and `set-value`: act on accessibility elements (M)

- **Why:** this is the highest-value new feature.
  - **Text entry:** typing any Unicode text into a field without the pasteboard or the keyboard removes the Mac clipboard risk (AGENTS.md) and the US-layout limit.
  - **Labels, not coordinates:** controls are pressed by label or identifier.
  - **Docs:** it closes the "Accessibility actions" open question and the README follow-up.
- **Read:** NeoSimulator #625.
  - **Request construction:** `N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:417-497`. It uses `+[AXPTranslatorRequest requestWithTranslation:]`, `setRequestType:`, `setAttributeType:`, `setActionType:`, `setClientType:` and `setParameters:`, sends with `sendAccessibilityRequestAsync:completionQueue:completionHandler:`, and reads the response's `resultData` and `error`.
  - **Press:** request type 7, action 5. The result is an `NSNumber`; anything other than true means refused.
  - **Set value:** request type 8, attribute 53, parameters `["value": text]`.
  - Both are in `N:NeoSimulatorDeviceIO/Simulator/SimulatorAccessibility.swift:59-65,94-133,170-204`.
  - **Caveats:**
    - Set-value always answers OK, even for an element that takes no value, so read the value back (`:174-176`).
    - Re-read the elements before acting, because setting a value can raise the keyboard and move elements (`:169-173`).
    - A disabled button answers a press and does nothing; check enabled first (`:17-18`).
    - A secure field reads back one `•` per UTF-16 unit (`N:NeoSimulatorManager/Logins/NativeFormSignIn.swift:243-259`).
  - **simdrive's side:** `S:SimDriveNative/Accessibility/SimulatorAccessibility.swift` already holds snapshot elements with translations (around 180-186) and sends through `AccessibilityChannel` (`S:SimDriveNative/Simulator/SimulatorDevice.swift:115-176`).
- **Do:**
  1. Add `perform(_ action:, on element:)` to `SimulatorAccessibility`, where the action is `press` or `setValue(String)`.
  2. In `SimDriveCore/Accessibility/`, resolve a target from `--label <text>`, `--id <identifier>` or `<x> <y>`. Use a fresh snapshot, require exactly one match, and fail with `no-element` or a new `ambiguous-element` code.
  3. Add commands `press <target>` and `set-value <target> <text>`. `set-value` returns the value read back.
  4. Consider using client type 2 (I8) so that elements under an alert can be acted on.
  5. Skill: prefer `set-value` over `type` for non-US text, and note that it sends no key events, so per-keystroke delegates don't fire.
- **Test:**
  - The probe's text field (a `UITextField` in `Evaluation/Probe/main.swift`; give it an `accessibilityIdentifier`, as `play-button` has): `set-value --id <its identifier> "Grüße 東京"`, then `tree` shows the value and the probe logs `TEXT Grüße 東京`.
  - `press --id play-button` makes the probe log `TAP play`.
  - A disabled button is refused, and an unknown label gives `no-element`.
  - Add matrix checks, and parser tests for target selection.
- **Then:** find the action numbers for increment, decrement and scroll-to-visible by logging the translator's requests in the bridge block, or by trying numbers near 5. Add `increment` and `decrement` for sliders and steppers.

### - [ ] N16. `web pages` and `web eval`: Web Inspector for web views (M)

- **Why:** accessibility misses web content's DOM and state. With JavaScript, an agent can read a page, fill forms reliably, and check app state in hybrid apps.
- **Read:** NeoSimulator #607, `N:NeoSimulatorDeviceIO/Simulator/SimulatorWebInspector.swift`, 447 lines of plain Foundation and Darwin code.
  - **Socket:** a host Unix socket whose path is the guest's `RWI_LISTEN_SOCKET` environment variable, read with `SimDevice getenv:error:` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:379,1128-1138`).
  - **Framing:** a 4-byte big-endian length, then a binary plist `{__selector, __argument}`. Each argument carries `WIRConnectionIdentifierKey` with a UUID for the connection (`SimulatorWebInspector.swift:340-411`).
  - **Handshake:** send `_rpc_reportIdentifier:` (`:186`).
  - **Pages:**
    1. Send `_rpc_getConnectedApplications:` (`:97`).
    2. Read `_rpc_reportConnectedApplicationList:`, then send `_rpc_forwardGetListing:` per app.
    3. Read `_rpc_applicationSentListing:`, whose `WIRListingKey` has `WIRPageIdentifierKey`, `WIRURLKey` and `WIRTitleKey`. A page with another client's `WIRConnectionIdentifierKey` is already being inspected (`:201-238`).
  - **Eval:**
    1. Send `_rpc_forwardSocketSetup:` with app, page, `WIRSenderKey` and `WIRAutomaticallyPause: false`.
    2. Read `Target.targetCreated` from `_rpc_applicationSentData:` to get the `targetId`.
    3. Send `_rpc_forwardSocketData:` with `Target.sendMessageToTarget`, wrapping `Runtime.evaluate` with `returnByValue: true`.
    4. Match the `Target.dispatchMessageFromTarget` reply by `id`.
    5. Send `_rpc_forwardDidClose:` when done (`:249-337`).
  - **Timeouts:** 15 s to start and 5 s per answer (`N:NeoSimulatorDeviceIO/DeviceOperationPolicy.swift:73-76`). The service can exit with its last connection, and launchd then delays its restart by about 10 s (`SimulatorWebInspector.swift:61-63`), so the daemon should hold one connection.
  - **Inspectable pages:** Safari, `SafariViewService` (SFSafariViewController and ASWebAuthenticationSession), and an app's `WKWebView` with `isInspectable = true`.
- **Do:**
  1. Add a `SimDriveNative/WebInspector/` driver and `getenv` on `SimulatorDevice`.
  2. Add commands `web pages`, returning `[{"app", "bundleID", "page", "url", "title", "inUse"}]`, and `web eval [--page N] <js|->`, returning the value as JSON, or an error with the exception text.
  3. With no `--page`, use the frontmost app's only page.
- **Test:** the probe adds an inspectable `WKWebView` loading a local HTML string. `web pages` lists it; `web eval "document.title"` returns the title; a thrown exception returns its message. Add matrix checks.

### - [ ] N17. Point agents at simslim for slimmed simulators (M, mostly verification; unverified)

- **Why:**
  - [simslim](https://github.com/MobAI-App/simslim) (reviewed at `f56a5a0`) turns off the ~175 background daemons a simulator doesn't need. Its README measures one iOS simulator going from 258 processes and 4.0 GB to 70 processes and 0.9 GB.
  - That fits more simulators, one per agent, on one Mac.
  - It also cuts log noise (see the `--system` filter in `logs`), CPU use and timing jitter.
  - NeoSimulator ports its catalog (`N:NeoSimulatorKit/Devices/BackgroundServices.swift`, `BackgroundServiceCatalog.swift`). simdrive doesn't need to: simslim is a maintained CLI with `--json`.
- **Read:** simslim's README, `profiles.go` (categories and their launchd labels), and `features.go`. `simslim doctor <udid> --requires <feature>` checks a feature against the slim profile.
- **Do:**
  1. Don't wrap or reimplement simslim. In the skill, add a short section for when an agent runs several simulators or reads noisy logs:
     - Install with `brew install mobai-app/tap/simslim`.
     - `simslim on <udid>` slims and reboots; `--no-reboot` keeps the current boot.
     - `simslim boot <udid>` waits for services, unlike `simctl bootstatus` on Air and Duo (F3).
     - `--except <category>` and `--keep <label>` keep what an app needs; `simslim off <udid>` restores stock.
     - Slim only simulators the agent created, since it changes the device until `off`.
  2. Add a line to the README.
  3. List in the skill the categories that any simdrive command needs, as `--except` values.
- **Verify:**
  - On simulators you created, `simslim on` each of: an iPhone on the oldest and newest iOS runtimes, a Duo and an Apple TV.
  - Run the full matrix on each and compare it with a stock run. At risk:
    - `logs`, for crash reports and system entries: `telemetry` stops `diagnosticextensionsd` and other diagnostics daemons.
    - `pasteboard` and `posture`, through CoreDevice.
    - `settings`, through Preferences notifications.
    - `tv`: `connectivity` stops `com.apple.tvremoted`.
    - `tree`.
  - Record breakages in `docs/device-behavior.md`, with the category that causes them.
  - Time `--timing` stock and slim. Note any change in early-boot failures (F7, F9).

### - [ ] N18. `standby on|off` on iPhone Duo (M, unverified on simdrive's CoreDevice)

- **Read:**
  - NeoSimulator #603 and #604 use CoreDevice's `com.apple.coredevice.feature.standby`, through `StandByCapability`, then `presentStandBy()`, which returns a `StandBySession` released with `invalidate()` (`N:NeoSimulatorPresentationAdapters/Native/CoreDeviceStandBy.swift:6-47`).
  - The installed CoreDevice (651.32) may instead export `showStandBy()`, `hideStandBy()`, `set(standByShowing:)` and `currentStandByState()`; bind the name that exists.
  - The device must be locked first: NeoSimulator presses Lock until `com.apple.springboard.lockstate` reads 1 (`N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:1005-1046`).
  - Other devices set the state of `com.apple.springboard.ambient.presentation` instead (`:958,994-1003`).
- **Do:** a `CoreDeviceStandBy` driver in `SimDriveNative/DeviceControl/`, opened through `LazyCapability`. The session lives in the daemon while StandBy is shown. This needs I6's lock-state read.
- **Test:** on a Duo you created, in landscape, `standby on`; the screenshot shows StandBy. `standby off` returns.

### - [ ] N19. `scene-size <width> <height>`: resize a resizable app (L, unverified)

- **Read:** `N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceAppResize.swift`.
  - **Feature:** `com.apple.coredevice.feature.resizableappmanagement` (`:81`).
  - **Calls:** `observeFrontmostAppResizability()`, `getDisplayForResizing()` and `startResizableSession(withDisplayId:preferredSize:cornerRadius:)` (`:119,139,145`).
  - **Session:** it has `adjustGeometry` and streams `sceneStateUpdates`. The scene keeps its size only while the session is held.
- **Why:** testing size classes and layouts at arbitrary widths, as on iPad windows.
- **Do:** first check which simulators list the feature (`CoreDeviceRemote.supports`). If iPads do, add a driver and a command that holds the session in the daemon.
- **Test:** the probe logs `SIZE w h` from `viewWillTransition(to:with:)`.

### - [ ] N20. VoiceOver, color filters and look-and-feel settings (L, needs I10)

- **Do:** with I10's driver, add settings rows for:
  - `voiceover`, a toggle;
  - `color-filter`: `none`, `grayscale`, `protanopia`, `deuteranopia`, `tritanopia` or `tint`, with an intensity, on iOS 27 and later;
  - `look-and-feel`: `clear` or `tinted`, on iOS 27 and later;
  - `glass-opacity`, if it differs from `glass-tint`.

  See `N:NeoSimulatorKit/Devices/SimulatorGuestSettings.swift:89-179` for the input and output shapes. VoiceOver changes how input behaves, which is why simdrive left it out; document what it breaks.
- **Test:** the probe logs `UIAccessibility.isVoiceOverRunning` and the color filter status in its `STATUS` line; add to the matrix's `settings` section.

### - [ ] N21. Mouse pointer on iPad (L, unverified on simulators)

- **Read:** NeoSimulator #561. It creates a `touchscreenGesture` service on `remote.universalhidservice` (`N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceHIDService.swift:106-110`) and translates synthesized mouse `NSEvent`s with an `EventObserver` covering all event types and a `coordinateTransform` (`N:NeoSimulatorPresentationAdapters/Native/CoreDeviceScreenInput.swift:640-644,883-912`; `N:NeoSimulatorPresentationAdapters/Native/CoreDeviceHIDReports.swift:113-116`). #561 targets physical devices.
- **Why:** hover effects, pointer interactions and right-click context menus on iPad.
- **Do:** first check on an iPad simulator that pointer reports reach the guest. Then add `hover <x> <y>` and `click <x> <y> [--right]`.

### - [ ] N22. Independent fingers (L)

- **Read:** `UniversalHID.DigitizerReport` contacts with identities, sent to `HIDServiceID.mainTouchscreen` after creating a `touchscreenGesture` service (`N:NeoSimulatorPresentationAdapters/Native/GuestScreenInput.swift:77-123`; `CoreDeviceHIDReports.swift:9-86`). Edges are set with `setContactSwipeUp`, `Down`, `Left` and `Right`, and the maximum is 2 contacts (`CoreDeviceHIDReports.swift:61`).
- **Why:** staggered two-finger gestures, which N9's fingers that start and end together don't cover. Low value until a test needs it.

### - [ ] N23. Apple TV Remote touch surface (L, fragile)

- **Read:**
  - `SimulatorKit.SimDeviceLegacyHIDClient` sending `IndigoHIDMessageForTrackpadMoveEvent(point, 0x16)`, with bytes patched per Xcode version: it is checked for Xcode 26.6 and 27.0-27.2 (`N:NeoSimulatorPresentationAdapters/Simulator/SimulatorPresentationRuntime.swift:571-678,940-960`; `N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:885-925`).
  - This is the legacy client that no longer delivers keys (`docs/design-decisions.md`), but NeoSimulator shows touch still gets through.
- **Why:** swipe-based tvOS interactions, such as scrubbing. The arrow buttons already move focus.

### - [ ] N24. Display Zoom (L)

- **Read:**
  - `App/NeoSimulatorGuestSettings/main.m` in NeoSimulator is a guest-side helper, built for the simulator SDK and run with `simctl spawn`.
  - It uses `DBSDisplayZoomConfigurationController` and `SFBDisplaySetCanvasSize`, posts `DBSMagnifyModeDidChangeNotification`, and relaunches SpringBoard with `SBSRelaunchAction`.
- **Why:** checking layouts under Display Zoom.
- **Cost:** a guest binary to build and sign per runtime, like `Evaluation/build-probe.sh`.

### - [ ] N25. `fill-login`: sign in without exposing credentials (L, needs N15 and N16)

- **Read:**
  - NeoSimulator #618-#625: `N:NeoSimulatorManager/Logins/NativeFormSignIn.swift` and `WebAuthenticationSignIn.swift`.
  - **Native forms:**
    - The password field is the only text field with subrole 5 (secure).
    - The user name is the field before it; the submit button is the first one after it, or the one named by label or `#identifier`.
    - It fills with set-value and presses with press (`NativeFormSignIn.swift:126-277`).
  - **Web sheets:**
    - It taps the SpringBoard consent alert's trailing button.
    - It fills fields found by `autocomplete` through Web Inspector JavaScript, using the `HTMLInputElement.prototype.value` setter plus `input` and `change` events, then `requestSubmit` (`WebAuthenticationSignIn.swift:163-229,437-487`).
    - It declines "save password" (`:520-551`).
- **Why:** an agent can sign in to test accounts kept in the Mac keychain or an environment variable, without the password entering its context.
- **Do:** after N15 and N16, `fill-login --keychain <service>` or `--env USER_VAR,PASS_VAR`.

## Not planned

- **Scroll wheel and trackpad gestures:** the guest drops them unless they come from a real Mac HID device (`N:NeoSimulatorPresentationAdapters/Native/CoreDeviceScreenInput.swift:318-319,388`). Drags already scroll.
- **NeoSimulator's control-socket CLI (#619):** it offers only `logins` and `sign-in`, and needs the NeoSimulator app running. N25 covers its use.
- **Screen connection, USB capture, virtual-machine client and device reports:** these serve physical devices (`N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceScreenConnection.swift`, `RemoteScreenCaptureSource.swift`, `CoreDeviceVirtualMachineClient.swift`, `N:NeoSimulatorKit/Devices/DeviceReports.swift`). `logs` already reads simulator crash reports.
- **Video recording through CoreDevice:** `simctl io recordVideo` covers simulators. A `record start|stop` command over `simctl` (stopped with SIGINT, waiting for "Recording started", as `N:NeoSimulatorKit/Simulator/Capture/VideoRecording.swift:56-96` does) is cheap, if agents ask for it.
- **External displays, CarPlay and audio routing:** costly, and of little use to agents.
