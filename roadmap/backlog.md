# Backlog

Work found by reviewing [NeoSimulator](https://github.com/lynnswap/NeoSimulator) at `d467c60` (2026-11-17), 50 commits past the `1dfc4af` that simdrive's guest input was ported from, then [AXe](https://github.com/cameroncooke/AXe), [idb](https://github.com/meta/idb) and [agent-device](https://github.com/callstack/agent-device) (2026-11-18). Ordered by kind (fixes, then improvements to existing commands, then new features), and within each kind by cost.

## Conventions

- **Cost**: S is under half a day, M one to two days, L several days. Costs include tests and docs.
- **Paths**: `S:` is simdrive's `Sources/`, at `bdfde5b`. `N:` is NeoSimulator's `Sources/`, at `d467c60`. Line numbers drift; the symbols named next to them do not. Get the reference with:

  ```sh
  git clone https://github.com/lynnswap/NeoSimulator /tmp/NeoSimulator && git -C /tmp/NeoSimulator checkout d467c60
  ```

  `A:` is AXe at `cb30a64`, `I:` idb at `5f5a5fb`, `D:` agent-device at `655ede2` and `M:` [MobileBuildMCP](https://github.com/getsentry/MobileBuildMCP) at `2998ac7`, each from the repository root.

- **Upstream review of 2026-11-24**: items and notes from the second review cite NeoSimulator at `c9710cf` (v0.10.3 and 13 commits since `d467c60`) and AXe at `1ffbd35` (v2.1.1 and staging builds). AXe's relicense rewrote its history: `cb30a64` is no longer reachable, and `9dfd60d` holds the same code, so `A:` paths at `cb30a64` resolve there. Older `N:` and `A:` line numbers have drifted, but every file they cite still exists. **AXe is GPL-3.0-only since v2.1.0**; simdrive is MIT, so take ideas and measurements from it, never code.

- **Every item** follows [AGENTS.md](../AGENTS.md): "Adding a capability" for structure, the README and skill for docs, and [docs/](../docs) for what was learned. Verify on simulators you created with `swift build -c release`, then `Evaluation/matrix.py <udid>`. Measure speed claims with `--timing --label <name>` before and after (`SIMDRIVE=<path>` runs another build).
- **Unverified** marks a claim taken from NeoSimulator's code or CoreSimulator's strings that nobody has run in simdrive.
- Tick an item when it is merged, and move what was learned into `docs/`.

## 1. Fixes

### - [x] F28. Xcode 27.3 removes `IndigoButtonEvent`, which every guest connection resolves (S–M, do first)

**Result:**
- **The fix:** buttons now go through a `mainScreenButtons` service on `remote.universalhidservice`, sent `CustomButtonReport`s, as NeoSimulator's d0a049b does. The service is created on the first press and kept until the idle release.
- **Codec:** `GuestMessageCodec.init` no longer resolves `IndigoButtonEvent`.
- **Legacy route:** kept, at the user's request, behind `button --legacy` (`LegacyGuestButtons`). It resolves the old type only when asked for, and fails with the new `legacy-buttons-unavailable` code where the type is gone.
- **iPhone 17, iOS 27.2:** the matrix's `buttons` and `basics` sections pass 15/15, volume included, judged from its HUD screenshot. The `tree`, `tap`, `keys` and `misc` sections pass 61/61 with the slimmer codec. `button home`, with and without `--legacy`, sends the probe to the background.
- **Apple TV 4K, tvOS 18.0:** the `tv` section passes 15/15. On the new route, down, up, select and menu (Back) all move focus as expected in Settings, and `--legacy` still works.
- **Not done:**
  - Not run on Xcode 27.3, which is not installed. That the other families survive there rests on NeoSimulator's report.
  - Step 3's lazy resolution was done only for the button family. Digitizer, request and orientation still resolve together, since 27.3 keeps them.
  - tvOS 26 and 27 runtimes are not installed.

- **Problem:** NeoSimulator #631 and PR #632 reproduce it on Xcode 27.3 (27C5035i), whose CoreDeviceUtilities 699.2.0 no longer has `CoreDeviceUtilities.IndigoButtonEvent`.
  - simdrive resolves that type in `GuestMessageCodec.init` (`S:SimDriveNative/Guest/GuestMessageCodec.swift`, `buttonEvents`), and every `SimulatorGuest` builds that codec. So on 27.3, opening any guest service fails, and keys, taps, orientation and buttons would all stop working, not just `button`. That part is inferred from the code; simdrive has not been run on 27.3.
  - On the installed 27.2 (CoreDeviceUtilities 651.32), both `IndigoButtonEvent` and its replacement, `CustomButtonReport.init(usage:down:)`, exist, along with the `mainScreenButtons` descriptor (checked with `nm`), so the switch needs no version check.
- **Read:**
  - NeoSimulator's fix, d0a049b: `N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceButtonReports.swift:1-46 @c9710cf` builds `UniversalHID.HIDUsage(page:usage:)`, then `CoreDeviceUtilities.CustomButtonReport(usage:down:)`, then its `.report`.
  - `N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceHIDService.swift:112-115 @c9710cf` adds the `HIDServiceType.mainScreenButtons` descriptor.
  - `N:NeoSimulatorPresentationAdapters/Native/GuestScreenInput.swift:127-176 @c9710cf` creates the service on the first press and reconnects when its transport failed or the service was removed. On stop it releases held buttons, then removes the service, then flushes.
  - In simdrive: `S:SimDriveNative/Input/GuestButtons.swift`, and `GuestKeyboard.swift` for how a UniversalHID service is created.
- **Do:**
  1. Send buttons as `CustomButtonReport`s through a `mainScreenButtons` service on `remote.universalhidservice`, the way `GuestKeyboard` does its keyboard. Keep the 400 ms settle after creating the service (`docs/private-apis.md`), and keep the service until the idle release, so a press doesn't pay that wait every time.
  2. Delete `buttonEvents` and the `.buttonEvent` message type from `GuestMessageCodec`.
  3. Resolve the codec's message families lazily, each where its driver first needs it, so a type a future Xcode removes takes only its own capability down, reported as `open() -> nil` or a named error.
  4. On Apple TV, check that `mainScreenButtons` carries the remote's consumer-page usages: menu 0x223, select and arrows 0x41–0x45, channel 0x9C/0x9D. NeoSimulator sends those through SimulatorKit instead (`N:NeoSimulatorPresentationAdapters/Simulator/SimulatorPresentationRuntime.swift:593,656-657 @c9710cf`), so this is unverified.
  5. Update `docs/private-apis.md` (the `remote.hid.button` row) and the README's tested Xcode versions.
- **Test:** the matrix's buttons and `tv` sections on 27.2. Then every section on Xcode 27.3 once it is installed.

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

### - [x] F7. Accessibility reads take up to a minute to fail, and fail after first boot (M)

**Result:** on a Duo iOS 27.2, the first `tree` after `bootstatus` failed 3 of 3 boots: the server names no app for several seconds, and reads stopped after 3 tries. A read now retries until one 20 s deadline across its requests, not 8 s: the first read takes 13–15 s. The first `tree` then succeeded on 7 of 7 boots, in 14–18 s. Sessions start the server with a request in the background; a `screenshot` first did not shorten the next `tree` reliably, since the screenshot takes 10–14 s itself (F14). A nil reply is `accessibility-unavailable`, and error 8 is `no-element`, neither seen in testing. `LazyCapability` now shares an open in progress, which the background request needs.

- **Problems:**
  - A read retries 3 times, 0.5 s apart, with a per-request limit (`S:SimDriveNative/Accessibility/SimulatorAccessibility.swift:31-41,124-176`), and makes two requests: the frontmost app, then its snapshot. Its worst case runs to tens of seconds; NeoSimulator bounds a whole read at 5 s (`N:NeoSimulatorDeviceIO/DeviceOperationPolicy.swift:71`, `N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:455-462`).
  - The first request after a boot starts the guest's accessibility server, which then names no app for some seconds (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:1084-1088`), hence the `accessibility-timeout` the README tells agents to retry.
  - `AccessibilityChannel.send` returns nil both for a timeout and for a completion without a response (`S:SimDriveNative/Simulator/SimulatorDevice.swift:166-176`). NeoSimulator reports a nil response as an unreachable service, and error 8 as an element that is gone (`N:NeoSimulatorDeviceIO/Simulator/SimulatorAccessibility.swift:131-133`, `CoreSimulator.swift:482-486`).
- **Do:**
  1. Give each `tree` one deadline across all of its requests and retries, about 8 s.
  2. When a session opens, send one frontmost-app request in the background, without waiting, to start the guest's accessibility server early.
  3. Split the nil result into "no answer in time" (`accessibility-timeout`) and "unreachable" (new `accessibility-unavailable`). Map error 8 to `no-element`.
- **Test:** on a simulator just booted from shutdown, `tree` succeeds on the first call more often than before; record the result in `docs/device-behavior.md`. Add unit tests for the deadline arithmetic if it is factored out, and run the matrix's `tree` section.

### - [x] F8. The daemon keeps its session across a reboot (M)

**Result:** before each request the daemon compares `isBooted` and `lastBootedAt` with the session's, and reopens it on a change; a `not-booted` reply makes it exit. A guest connection error also releases the inputs. Not reproduced with the old build on a Duo iOS 27.2: after 9 s and 20 s reboots, its `tap` reached the probe and `posture` read the new boot's hinge. After many quick reboots the guest's accessibility server stopped answering, with or without the daemon, until one more reboot.

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

### - [x] F14. The first `screenshot` after a boot takes 10–14 s on the Duo (S)

**Result:** the guest's orientation read took 2.7–7.6 s of it; listing the displays and reading the hinge took under 1 s each. A screenshot now waits at most 1 s for the orientation, recording null past that, and the read goes on for later commands. Right after `bootstatus` on a Duo iOS 27.2, the first `screenshot --no-daemon` takes 3.5–4.6 s and through a new daemon 4.8–11.5 s, from 7–10.5 s and 10–14 s. The matrix's `basics` and `posture` pass on the Duo, `basics` and `orientation` on an iPhone.

- **Problem:** found testing F7. On a Duo iOS 27.2, `screenshot` right after `bootstatus` took 10.3–14.2 s, against under 1 s warm. Screenshots read the framebuffer in process, and read the device orientation only to record it (F9).
- **Do:** time the framebuffer read, the display listing and the orientation read separately right after boot; skip or bound whichever waits on the guest.
- **Test:** on a Duo you created, `screenshot` within a second of `bootstatus` returning, on three boots; then the matrix's `basics` and `orientation` sections.

### - [x] F15. The Duo's accessibility server stops answering until a reboot (M, cause unknown)

**Result:**
- **"Do first" is done:** before the session's first accessibility read, including the background one a session sends as it opens, `DeviceAccessibility` waits until a screen has started, polling every 250 ms for up to 60 s. Past that, it fails with the new, retryable `simulator-starting` code.
- **The signal, measured:** CoreSimulator's screen properties report a backlight state of -101 (unknown) on every screen early in a boot. On a cold iPhone, iOS 27.2, the main panel reported 2 at 85 s, 25 s after its interface orientation (at 60 s). Settled devices:
  - An iOS 17.0 iPhone reports 2.
  - A Duo reports 2 on its cover panel and -101 on its inner panel, so any started screen counts.
  - An Apple TV, tvOS 18, reports -101 even when settled, so it skips the wait. Its reads were never affected.
- **Checks:**
  - A `tree` 3 s into a cold iPhone boot waited, then returned the Home screen after 55 s, and the next read was instant.
  - On a cold Duo, the first `tree` failed after 60 s with `simulator-starting`, and every later read worked.
  - `ScreenAdapterTests` cover the decision.
- **Not reproduced:** the stuck state itself, so this fix rests on AXe's diagnosis and F15's timing clues. If it recurs, follow "Research next time it happens" below before rebooting.

- **Problem:** seen twice on a Duo iOS 27.2 under Xcode 27.2 (`688B6C57`), never on an iPhone. Every read went unanswered for minutes while the probe showed in front: `tree` failed with `accessibility-timeout` after its 20 s deadline, and `launch` with `launch-not-frontmost`, since `becomesFrontmost` reads the same server. A fresh daemon and `--no-daemon` failed alike, so it is the guest's state, not simdrive's session. Screenshots, taps and `posture` kept working. A reboot cleared it both times; reinstalling the probe neither caused nor cleared it.
- **What came before:**
  1. 22:41–22:53: five quick reboots in about six minutes while testing F8, the hinge set open before some of them. The first failure was a `tree` right after `posture open`; a reboot cleared it, then the next reboot brought it back, and it held for five minutes, across daemon restarts, until another reboot.
  2. 22:55 boot, hinge closed, then 12 minutes idle. At 23:07 the matrix ran `doctor`, installed the probe, set `orientation portrait` and launched it at 23:08:23; reads failed from then on. Idle display sleep (I6) fits the idle period, but the screenshot taken during the failure was not dimmed.
- **Clues:**
  - Each read reached the guest: `CoreSimulatorBridge` logged `[com.apple.Accessibility:AXSupportCommon] Read CategoryName` at every attempt (23:09:05, 23:09:26, 23:09:27), and its `com.apple.CoreSimulator.accessibility.peer` connection stayed open until the daemon exited. So `sendAccessibilityRequestAsync` was delivered, but no reply came back: the failure is `unanswered`, not `unreachable` (`S:SimDriveNative/Simulator/SimulatorDevice.swift`, `AccessibilityChannel`).
  - The launch itself succeeded in the guest log (`Launch successful for 'com.simdrive.axprobe', pid: 68904`), and the probe loaded its accessibility settings.
  - Info-level accessibility entries (`AXRuntimeNotifications`, `AXLoading`) are missing from the stored guest log in healthy periods too, so their absence during the failure proves nothing. Stream the log live instead.
  - F7's slow start is a different symptom: there the server answered with no app, here it does not answer.
  - **Likely cause:** AXe documents the same state on iOS 27.2: "an accessibility read made in the first seconds after boot, before the guest publishes its displays, left every later read on that simulator returning 'No translation object' until it was rebooted" (`A:Sources/AXe/Utilities/AccessibilityFetcher.swift:136-169`). simdrive's session sends such a read in the background as it opens (`DeviceAccessibility.prepare`, from F7), and both occurrences followed a command run right after `bootstatus`: the F8 reboots, and at 22:55 a `posture` seconds after boot, whose session sent that read; every read after it failed, from a new daemon 12 minutes later too.
- **Do first:** before a session's first accessibility request, wait until the device's displays can be read, as AXe does: poll every 250 ms for up to 60 s, and past that fail with a code that says the simulator is still starting. Then reproduce: a `doctor` within a second of `bootstatus` returning, on several boots, should no longer leave reads stuck.
- **Research next time it happens, before rebooting:**
  1. `sample` the guest's `CoreSimulatorBridge`, `SpringBoard` and `AccessibilityUIServer` during a `tree`: they run as Mac processes. Find their pids in the guest log (`Process[pid:…]`) or with `lsof -p <pid> | rg <udid>`. Look for the thread that handles the accessibility request and what it waits on.
  2. Stream `simctl spawn <udid> log stream --level debug --predicate 'process == "CoreSimulatorBridge" OR subsystem == "com.apple.Accessibility"'` during a `tree`, and compare it with a healthy one.
  3. Check whether a hit test (`tree <x> <y>`) also hangs, or only the frontmost-app request.
  4. Try recovering without a reboot: `simctl spawn <udid> launchctl kickstart -k system/com.apple.CoreSimulator.bridge`, then `com.apple.AccessibilityUIServer`; then `lock`, `lock` and an edge swipe, in case the display slept. If one works, simdrive could do it after repeated unanswered reads.
- **Reproduce:** on a Duo you created, alternate `posture open|closed`, `simctl shutdown` and `boot` five times within a few minutes, then `launch` the probe and `tree`; separately, leave a booted, closed Duo idle 15 minutes, then run the matrix.

### - [ ] F16. A bottom-edge swipe does not go home on a new iPhone iOS 17.0 (S, cause unknown)

- **Problem:** on an iPhone 15 iOS 17.0 created and booted for I4 (`77657B7A`, Xcode 27.2), the matrix's `swipe --edge bottom (go home)` and `unlock (lock, edge swipe)` fail every run, with the I3 build too; the swipe returns `ok` and the probe stays active. `button home` works. `docs/device-behavior.md` records edge swipes working on iOS 17.0 before.
- **Do:** check whether a first-boot state, such as the home-indicator tutorial, eats the gesture: screenshot during the swipe, retry after a reboot, and try a longer `--duration` and a start at 0.995. Retry first with F17's fix, which may be the cause.

### - [x] F17. `split` returns `ok` when the drag opens the app switcher (S)

**Result:** on a new connection the guest takes about 215 ms to handle its first message, so a drag's first touches arrived bunched, then held: a swipe that stops, which opens the app switcher. That happened on 3–4 of 5 splits through a new daemon, and on none through a warm one. Opening the touchscreen now waits for a barrier, and fresh splits went 6 of 6. `split` also no longer trusts accessibility, which reads the switcher's card as a half: it streams SpringBoard's published layout during the drag and accepts the app's frame in the target half, falling back to one `log show`. A split takes 1.23 s, against 1.30 s.

- **Problem:** on a new Duo iOS 27.2, `split left --from full` and `split right --from full` returned `ok` with the app switcher showing.
- **Test:** `DisplayLayoutTests`; on a Duo you created, `stop` then `split right --from full`, five times.

### - [x] F18. Apps launched after Full Keyboard Access is turned off have no tree (S)

**Result:** on iOS 27, backboardd turns `ApplicationAccessibilityEnabled` off when the Full Keyboard Access process quits, and an app launched while it is off answers with an empty frame until it relaunches; no notification wakes it. `launch` now turns it on first, about 0.4 s, and `tree` reports `app-accessibility-off` when it finds an empty frame with the preference off. iOS 17.0 keeps the preference on. The matrix's `basics`, `tree` and `settings` pass on iPhone iOS 17.0 and 27.2; Max on iPad iOS 27.0 reads again after `launch`.

- **Problem:** found driving Max on an iPad iOS 27.0. After `setting full-keyboard-access off`, `launch` failed with `launch-not-frontmost` though the app was in front, and `tree` with "The frontmost app has no frame yet; wait for it to finish launching" after its 20 s deadline, on every try. Turning Full Keyboard Access on brought both back.
- **Test:** the matrix's `settings` section on iPhone iOS 17.0 and 27.2.

### - [x] F19. The idle input release can close an input while a command is still using it (S)

**Result:** every input in `DeviceInputs` now runs inside `IdleRelease.hold`, which stops the pending release when the input starts and starts the idle period again when it ends; the release also checks that no input holds it. `IdleReleaseTests` fail without these two guards. The matrix passes 116/116 on iPhone 17, iOS 27.2. The input that crosses t=30 s was not run in the matrix.

- **Problem:** found in the architecture review (2026-11-24), read from the code but not run. `DeviceInputs.scheduleRelease()` runs only when an input finishes, so the timer from the previous input keeps running during the next one. The timer is a main-actor `Task`, which can run at the input's `pause` and `flush` awaits; serving one request at a time in the daemon doesn't stop that. Example: `tap` at t=0, then `key down --repeat 10`, `button lock --hold 2000` or a 1 s `swipe` that crosses t=30 s. `release()` removes the keyboard or drains the touchscreen partway through, and the command still returns `ok`.
- **Read:** `S:SimDriveCore/Input/DeviceInputs.swift` (`scheduleRelease`, `release`), `S:SimDriveNative/Input/GuestKeyboard.swift` (`close`).
- **Do:** cancel `idleRelease` when every input method starts, not only when it ends. Track inputs in flight, and skip the release while any is running.
- **Test:** a unit test with a short, injected idle interval and a fake input that awaits across it. In the matrix's `keys` section, add `key down --repeat 20` started 29.5 s after a tap.

### - [x] F20. One stuck tool or CoreDevice call blocks a device's daemon, `stop` included (M)

**Result:**
- **Tools:** `DeveloperTools.run` stops a tool past its limit and fails with `tool-timeout`: 60 s by default, 120 s for `log show`, 10 minutes for `install`. `Process.waitUntilExit` sees an exit only on the thread that launched the process, so launching on one thread and waiting on another hung about one `setting` read in 16; `toolsRunTogetherAllFinish` now catches that.
- **CoreDevice:** capability calls go through `CoreDeviceRemote.call`, limited to 15 s. A record with an unanswered call reads `hasFailed`, and the session then reopens it and the pasteboard. `SharedInitialization` keeps a run that outlasted a caller, so later callers wait on it instead of starting another.
- **`stop`:** answered ahead of the queue: 0.14 s while `run` with `wait 60000` was in progress, where it used to wait out the run. Shutdown waits at most 3 s for the session to close.
- **Checks:** unit tests prove each part fails when broken. The matrix passes 116/116 on iPhone 17, iOS 27.2. No real CoreDevice stall was reproduced.
- **Left:** the hinge keeps its record after a timeout (I19), the client still reads the reply without a limit (I9), and each running tool blocks two dispatch threads, so dozens at once in one process would stall until their limits (I18).

- **Problem:** found in the architecture review (2026-11-24), read from the code but not run. The daemon serves one request at a time, and several waits on it have no limit:
  - `DeveloperTools.runSynchronously` waits on `simctl` without one (`launch`, `spawn … defaults write`, `log show`, `io screenshot`, `get_app_container`).
  - The CoreDevice capability calls have none: the pasteboard's `current`, `replace` and `capture`, `CoreDeviceRemote.getImplementation`, and the hinge's `motionManager`. F6 limited only `awaitFullInitialization`.
  - `SharedInitialization.value()` forgets a run that timed out while it is still going, so each retry starts another `DeviceManager` and they pile up. On a Duo every tap passes through `hinge.value()`, so every tap waits 30 s.
  - `stop` waits behind the stuck request, and `DaemonClient.exchange` reads without a timeout, so the agent's shell hangs as well. Only killing the daemon recovers.
- **Read:** `S:SimDriveCore/Tools/DeveloperTools.swift`, `S:SimDriveCore/Daemon/DaemonServer.swift` (`respond`, `handle`), `S:SimDriveNative/DeviceControl/CoreDevicePasteboard.swift`, `S:SimDriveNative/CoreDevice/CoreDeviceRemote.swift`, `S:SimDriveNative/DeviceControl/CoreDeviceHinge.swift`, `S:SimDriveNative/Support/SharedInitialization.swift`; I9, which cancels requests whose client went away.
- **Do:**
  1. Give `simctlResult` a time limit, with a default per call, that terminates the process and fails with a new `tool-timeout` code.
  2. Wrap each CoreDevice call in `waitForCompletion(within:timeout:)`. After a timeout, mark the remote unusable (`hasFailed`, with `isUsable` on its `LazyCapability`) so the next use reopens it.
  3. Keep `SharedInitialization`'s run after a timeout, so later callers wait on it again; forget it only once it fails or finishes.
  4. Answer `stop` outside the request queue: cancel the request in flight, release the inputs, and exit.
- **Test:** unit tests for `SharedInitialization` keeping a run after a timeout, and for `simctlResult` killing a `sleep 60` stand-in. Check by hand: `stop` answers within 1 s while `run` with `wait 60000` is in progress.

### - [x] F21. `logs` in the command line writes a stale cursor and process name back after `launch` (S)

**Result:** `LogStore.update(forLaunchAt:)` drops a cursor or process-name write when a `launch` happened since its read, and every update holds an `flock` on `<udid>.logs.json.lock`. `LogStoreTests` fail without the check. On iPhone 17, iOS 27.2: build up four stdout lines, start a background `logs --until`, relaunch the probe and tap once; the next `logs` returns that tap's `TAP play stdout`. The matrix's `logs` section passes 35/35. The old build was not run against the same steps.

- **Problem:** found in the architecture review (2026-11-24), read from the code but not run. A top-level `logs` runs in the client process. It reads `LogStore` when it starts and writes its cursor when it ends, so a `logs --until` running in the background, as the skill suggests, can span a `launch`.
  - `recordLaunch` resets every cursor, but the client then writes back its earlier cursor, offsets into the old stdout file included. The new app's output goes to the same path, so the next `logs` skips its first bytes without saying so.
  - `target(of:)` likewise writes the old app's process name into the new app's record, and later reads then filter on the wrong process.
- **Read:** `S:SimDriveCore/Logs/DeviceLogs.swift` (`read`, `attach`, `target(of:)`), `S:SimDriveCore/Logs/LogStore.swift`.
- **Do:** give each cursor and the cached process name the `launchedAt` of the app they were read for. In `update`, drop a change whose launch no longer matches `contents.app`. Lock the file with `flock` around each read and write, since two processes write it.
- **Test:** a `LogStore` unit test: read, record a new launch, write the stale cursor, and check that it was dropped. In the matrix, run `logs --until never --timeout 5000` in the background, relaunch the probe, then check that `logs` returns its `TAP play stdout`.

### - [x] F22. The split side is never reset (S)

**Result:**
- **Why remember:** reading SpringBoard's last `DisplayLayout` took 4 to 30 s with `--info --debug` on a Duo, iOS 27.2, too slow to derive the side on every `tree`, so it stays remembered.
- **The fix:** the remembered side moved from `Screens`, which never used it, to `SplitState`. It now belongs to the pid of the app `split` moved, and is cleared when a move starts and on a posture change. `tree`, hit tests and `split` without `--from` ignore it for any other pid.
- **Relaunch:** on the Duo, a relaunched probe came back full screen with a new pid, where the old code would have kept the stale half.
- **Checks:** on a Duo you created, `split right --from full`, then `split left`, then a fold and unfold, each followed by `tap --id play-button`, which the probe saw every time. `split` after the fold asks for `--from`. `SplitStateTests` fail without the pid check.
- **Left:** an app whose half simdrive did not set still reads as if on the left. Deriving the side from SpringBoard's log, only when `split-side-unknown` would be thrown, is the remaining option.

- **Problem:** found in the architecture review (2026-11-24). `Screens.splitLayout` is set only by `split` and is never cleared: not on `launch`, `button home`, a posture change or a `split` that throws `split-dropped`. Example: after `split right` and `button home`, another app opening in the left half is read with the right half's origin, so `tree x y` misses (`no-element`) or its points shift by half the screen. The value lives in `Screens`, which never uses it; only `DeviceAccessibility` and `SplitView` read it.
- **Read:** `S:SimDriveCore/Screens/Screens.swift`, `S:SimDriveCore/Accessibility/DeviceAccessibility.swift` (`appOrigin`), `S:SimDriveCore/Split/SplitView.swift`, `S:SimDriveCore/Split/DisplayLayout.swift`.
- **Do:** derive the side from the last `DisplayLayout` SpringBoard logged, with one short `log show` when `fillsHalf` is true. That also removes `split-side-unknown`. If that proves too slow, move the state into `SplitView`, and reset it wherever screen records are reset.
- **Test:** on a Duo you created: `split right`, `button home`, launch the probe in the left half, then run `tree` at one of its elements.

### - [x] F23. Screen records outlive rotations of the interface alone (M)

**Result:**
- **Confirmed:** the probe's new `-probeLandscape` argument presents a landscape-only screen 3 s after launch, with no `launch`, URL or Home press, so nothing forgets the record. On an upright iPhone 17, iOS 27.2, the previous build sent `tap 0.25 0.3` to (0.300, 0.750).
- **The fix:** `Screens.screen` reads each display's interface orientation in process, and `ScreenshotRecord.isCurrent` compares it with the record's. A turned interface recalibrates fractions and fails pixels with `stale-screenshot`, the same as a rotated device. The same tap now lands at (0.250, 0.300). `ScreenshotRecordTests` fail without the comparison.
- **Cost:** `tap`'s median was 86 ms before. After, it was 198 ms, then 87 and 87 ms over three timing rounds. The first round ran right after a launch.
- **Checks:** the matrix's `tap` section checks the turn on iPhones (`tap after the interface turns alone`).
- **Not done:** the `forgetScreenshots` calls after `launch`, `openurl` and `button home` stay until the interface read is confirmed on iOS 17 and 18, where a nil reading skips the comparison. Not checked on iPad or Duo.

- **Problem:** found in the architecture review (2026-11-24). `Screens.screen` keeps using a record while the *device* orientation stays the same. Only `launch`, `openurl` and `button home` forget records, so these all leave a stale record that maps taps through the wrong rotation: tapping a landscape-only app's icon on SpringBoard, the app switcher, a video player that forces landscape, or a link handled inside the app. A pixel tap doesn't fail with `stale-screenshot` either. Keeping a value in sync this way, instead of deriving it, also spreads `forgetScreenshots` calls across `DeviceSession`.
- **Read:** `S:SimDriveCore/Screens/Screens.swift` (`screen`, `forgetScreenshots`), `S:SimDriveCore/Session/DeviceSession.swift`, `S:SimDriveNative/Simulator/SimulatorDevice.swift` (the interface orientation).
- **Do:** on each `screen()` call, read the screen's interface orientation in process and compare it with the record's. When they differ, recalibrate for fractions or throw `stale-screenshot` for pixels. Then delete the `forgetScreenshots` call sites. Measure what the extra read costs per tap first (`--timing`).
- **Test:** add a landscape-only scene to the probe, open it from SpringBoard by tapping its icon, then tap a fraction and check the probe's `TOUCH` line.

### - [ ] F24. Sessions share the accessibility translator, but each brings its own bridge and read state (M, unverified)

- **Problem:** found in the architecture review (2026-11-24). `AXPTranslator.sharedInstance` has one `bridgeTokenDelegate`, but each `SimulatorAccessibility` has its own queue, `AccessibilityBridge` and `AccessibilityRead`. After a reboot, the daemon opens a new session, whose `prepare()` replaces the delegate while the old session's read, which can take up to 20 s, still runs on its own queue. That old read then goes through the new bridge, under the new read's deadline, and writes its failure into the new read from another thread: a data race on an `@unchecked Sendable` object.
- **Read:** `S:SimDriveNative/Accessibility/SimulatorAccessibility.swift` (`open`, `init`, `AccessibilityBridge`, `AccessibilityRead`), `S:SimDriveCore/Daemon/DaemonServer.swift` (`openSession`).
- **Do:** give the translator, its bridge and one serial queue a single owner for the whole process. Keep each read's state per request, keyed by the token the callbacks already receive.
- **Test:** reboot a simulator you created while `tree` runs in a loop through the daemon, then check that the next `tree` answers; run once with Thread Sanitizer (`swift build -c release --sanitize=thread`).

### - [x] F25. Two daemons can start for one device, and a stopping daemon removes another daemon's socket (S)

**Result:** confirmed. Eight cold `doctor` calls at once start several daemons, and the lock turned six away over three rounds. Each daemon now takes an exclusive `flock` on `<udid>.daemon.lock` before it listens, and holds it until it exits, so a daemon that does not get it exits with `daemon-running` and never touches the socket. Three rounds on iPhone 17, iOS 27.2 each left one daemon and its socket. `FileLockTests` fail without the lock.

- **Problem:** found in the architecture review (2026-11-24). Two cold calls at once each spawn a daemon. `UnixSocket.listen` checks with `connect`, then unlinks and binds. If both daemons pass that check before either listens, the second unlinks the first daemon's socket. The orphaned daemon goes idle after 10 minutes, and its `shutdown()` then unlinks the socket path, which is by then the live daemon's. The next call starts a third daemon while the second still holds the guest's inputs.
- **Read:** `S:SimDriveCore/Daemon/UnixSocket.swift` (`listen`), `S:SimDriveCore/Daemon/DaemonServer.swift` (`run`, `shutdown`), `S:SimDriveCore/Daemon/DaemonClient.swift` (`connection`).
- **Do:** hold an exclusive `flock` on `<udid>.lock` for the daemon's whole life; a daemon that can't take it exits. Have `shutdown` unlink only while it holds the lock.
- **Test:** a unit test that starts two listeners on the same path in a temporary directory. By hand, run eight `simdrive <udid> doctor` calls at once from a cold start, then check that `pgrep -f "<udid> serve"` finds one daemon.

### - [x] F26. The state directory in `/tmp` is trusted without checking its owner (S)

**Result:** `StatePaths.prepare` checks `/tmp/simdrive-<uid>` with `lstat`. It refuses one that is a symlink or belongs to another user, failing with the new `state-directory` code, and sets its own back to 0700 when it is open to others. The client now prepares it before connecting to a socket there, including for `stop`, and opens the daemon's log with `O_NOFOLLOW`. `StatePathsTests` covers a new directory, an open one of your own and a symlink; the symlink test fails without the check. A directory owned by another user was not tested, since that needs a second account.

- **Problem:** found in the architecture review (2026-11-24). `StatePaths.directory` is `/tmp/simdrive-<uid>`, a predictable name in a directory every user can write to. `prepare()` accepts the directory if it already exists, whoever made it, and the daemon's log is opened with `O_CREAT | O_APPEND`, which follows symlinks. On a Mac with several users, another user who creates the directory first can redirect the log onto any file the victim can write, or answer on the socket in the daemon's place.
- **Read:** `S:SimDriveCore/Daemon/StatePaths.swift`, `S:SimDriveCore/Daemon/DaemonClient.swift` (`spawnDaemon`).
- **Do:** after `createDirectory`, `lstat` the directory and refuse, with a new `state-directory` code, unless it is a real directory owned by `getuid()` with mode 0700. Open the log with `O_NOFOLLOW`.
- **Test:** a unit test pointing `prepare` at a directory with mode 0777 and at a symlink.

### - [x] F27. The matrix's `openurl` checks miss the URL prompt on an iPhone Duo (S)

**Result:**
- **The prompt:** `accept_url_prompt` now runs `tap --label Open --timeout 2000`, and with no prompt it just finds no Open. On a fresh Duo, iOS 27.2, `openurl from-home` and `in-front` pass.
- **Also fixed:** the same run failed `settings restored` because the first `setting` read, right after that first boot, outlasted `simctl`'s 60 s limit with `tool-timeout`, which left the starting snapshot empty. `setting_snapshot` now runs it again when the error says `retry`.
- **Not rerun:** the `misc` section, after the retry fix.

- **Problem:** found verifying I19 (2026-11-24) on a fresh Duo, iOS 27.2. `openurl from-home` and `openurl in-front` fail: `openurl` returns `ok`, but the "Open in “AXProbe”?" alert stays on the inner screen, so the probe never logs the URL. `accept_url_prompt` reads the tree 1 s after `openurl` and finds no element starting with "Open in". `tap --label Open` dismisses the same alert.
- **Read:** `Evaluation/matrix.py` (`accept_url_prompt`, `misc_checks`).
- **Do:** replace the tree scan with `tap --label Open --timeout 2000`, treating `no-element` as no prompt.
- **Test:** the matrix's `misc` section on a fresh Duo and a fresh iPhone.

### - [ ] F29. A tap on the "Open in …?" URL alert is dropped on a new simulator, though it returns `ok` (M, cause unknown)

- **Problem:** found after F27 (2026-11-24), first filed as I25 on the guess that the alert was still animating in. Without the matrix's 1 s sleep before `tap --label Open`, the full matrix on a new iPhone 17, iOS 27.2, fails `openurl from-home` and `openurl in-front`, and the alert left up then fails 8 later checks (orientation, `button home`, launch from home, the Home edge swipe): 120/130 with v0.1.0 (2026-11-25). The matrix keeps the sleep meanwhile; agents tapping the alert at once hit the same drop.
- **Ruled out (2026-11-25):**
  - **Animation, as accessibility sees it:** reading `tree` every 100 ms from the moment of `openurl`, the Open button's point is final from the first read, so I25's planned fix, waiting for two reads to place the element alike, waits for nothing. It was written and backed out.
  - **The idle input release:** after 35 s idle, `tap --label Play` and `tap 0.5 0.17` each reached the probe, twice each.
  - **`tap --label` alone:** `--only misc` on a new simulator, with no sleep, passed 11/11 with v0.1.0 and with the I25 build. Only the full run reproduced it.
- **Seen on the kept simulator:** minutes later the alert was still up, fully drawn; `tap --label Open` returned `ok` and left it up, and `tap 0.6841 0.5423`, the same point, right after dismissed it. So a first tap on it is dropped, not one at a particular moment of the animation.
- **Reproducing:** iOS asks only for a scheme's first URL on a simulator; reinstalling the app does not ask again, so each try needs a new simulator: remove the sleep in `accept_url_prompt` and run `Evaluation/fresh.py --only tree,keys,misc` (about 3 minutes).
- **Narrowed (2026-11-25), each on a new iPhone 17, iOS 27.2, with no sleep:**
  - **Not display sleep or lock:** `doctor` right before each dropped tap read `backlight` `on` and `locked` false.
  - **Every tap on the alert fails within the run:** `openurl in-front` taps the alert left up by `from-home`, and that tap is dropped too. On a kept simulator, after a new daemon, the first `tap --label Open` was dropped and the second dismissed it.
  - **Sections:** `tree,tap,misc` and `tree,keys,misc` reproduce it (2 of 2 taps dropped each); `misc`, `tree,logs,misc` and `settings,misc` do not.
  - **Single steps do not:** a script on new simulators that launches the probe and, before `openurl` and `tap --label Open`, presses Home (2 runs), focuses the text field (2), focuses it then presses Home (1), types into it (1) or presses `key down` (1), delivered the URL on the first tap every time, against none pressed (2).
  - Kept, shut down: `DC718C97` (from `tree,tap,misc`) and `E4FD2121` (from `tree,keys,misc`), both `simdrive fresh iPhone 17 27.2`, the alert dismissed.
- **Next:** bisect inside the `keys` section, which is shorter: run its steps one by one before the URL in the script above (`key x --repeat 3`, `key tab`, the arrows, `type` with long text and `clear_field`). Then log the guest's touch handling for a dropped tap and a delivered one: `simctl spawn <udid> log stream --level debug --predicate 'process == "SpringBoard" OR process == "backboardd"'`.

## 2. Improvements to existing commands

### - [x] I1. Type without per-key delays (S)

**Result:** `type` sends each key's down and up with no wait, Shift only when it changes, and flushes once. 100 characters fell from 9.1 s to 0.3 s on an iPhone iOS 27.2. Doubled letters, mixed case and 200 characters type exactly on that iPhone and on a Duo iOS 27.2 (the matrix's `keys`), so no gap between identical keys was needed.

- **Problem:** `type` holds each key 40 ms (`GuestKeyboard.keyHold`, `S:SimDriveNative/Input/GuestKeyboard.swift:6,33`) and waits 40 ms after it (`DeviceInputs.Timing.keyGap`, `S:SimDriveCore/Input/DeviceInputs.swift:10,50`). It also sends a Shift change before and after every shifted character. That is at least 80 ms a character, about 8 s for 100. NeoSimulator sends key-down then key-up with no delay, sends a modifier change only when Shift actually changes, and sends one release at the end (`N:NeoSimulatorPresentationAdapters/Native/NativeDeviceKeyboard.swift:154-175`).
- **Do:**
  1. Add a `type(_ strokes:)` to `GuestKeyboard` that tracks the current Shift state across keys.
  2. Drop the hold and the gap, and flush once at the end (F1).
  3. Keep `press`'s hold for `key`, where it costs one key.
- **Test:**
  - The matrix's `keys` section (`key_checks` in `Evaluation/matrix.py`), extended with doubled letters (`"aabb"`), mixed case, and a long string (200 characters). The probe's `TEXT` lines must match exactly.
  - Time `type` with `--timing` before and after.
  - Some guests may merge same-key repeats without a gap. If doubled letters drop, keep a minimal gap, such as 5 ms, between identical keys only.

### - [x] I2. Drop the 400 ms wait when opening touch and buttons (S)

**Result:** on an iPhone and a Duo iOS 27.2, a `tap` on Play right after the inputs were released reached the probe 20/20 times, and `button home` 10/10. The full matrix passes on both. On the iPhone, a tap after release fell from 750 ms to 343 ms, and `tap --no-daemon` from 2.35 s to 1.89 s.

- **Problem:** `GuestTouchscreen.open` and `GuestButtons.open` wait `GuestInputTiming.settle`, 400 ms (`S:SimDriveNative/Input/GuestTouchscreen.swift:46`, `GuestButtons.swift:48`). They only open an XPC connection, though, and create no guest service, which is what the wait covers for the keyboard. NeoSimulator posts touches and buttons as soon as it connects (`N:NeoSimulatorPresentationAdapters/Native/GuestScreenInput.swift:18-33,125-149`). The wait costs 400 ms on the first input after every 30 s idle release.
- **Do:** remove the wait from those two, and keep it in `GuestKeyboard.open`, after `createService`.
- **Test:**
  - `simdrive <udid> stop`, then a single `tap` on the probe's Play button: the probe logs `TAP play`. Repeat 20 times.
  - The same with `button home` and a screenshot.
  - The full matrix on an iPhone and on the Duo, since the Duo needed longer waits before.
  - Time it with `--timing`.

### - [x] I3. Narrow simdrive's native symbol lookups (S)

**Result:** on an iPhone iOS 27.2, the median `tap 0.5 0.5 --no-daemon` fell from 1800 ms to 1735 ms, and `doctor --no-daemon` from 1215 ms to 1177 ms, over 16 runs each. The matrix's `basics` and `misc` pass on that iPhone, and `basics` and `posture` on a Duo iOS 27.2.

- **Problem:** `xpc_endpoint_create_mach_port_4sim` and `xpc_connection_enable_sim2host_4sim` are resolved in automatic scope (`S:SimDriveNative/Guest/SimulatorGuest.swift:21-24`), which searches every loaded image. NeoSimulator #574 limits them to libxpc with `in: ImageSelector.installName("/usr/lib/system/libxpc.dylib"), loading: .loadedOnly` (`N:NeoSimulatorDeviceIO/CoreDevice/SimulatorGuestHID.swift:21-25`). `CoreDeviceManager` also makes seven `resolve` calls outside any `prepare` batch (`S:SimDriveNative/CoreDevice/CoreDeviceRemote.swift:23-24,33-39`).
- **Do:** scope the two xpc lookups to libxpc. Move the resolves into one `runtime.prepare { … }` where they share a batch.
- **Test:** time `doctor --no-daemon` and `tap 0.5 0.5 --no-daemon` with `--timing`, several rounds, before and after. Combine with I5 if both are done together.

### - [x] I4. Change appearance, text size and contrast in process (S)

**Result:** on an iPhone iOS 27.2 through a warm daemon, changing one of the three fell from 720 ms to 277 ms, reading one from 420 ms to 275 ms, and listing every setting from 1247 ms to 1169 ms, which the `defaults export` spawns dominate. The matrix's `settings` section passes on iPhones iOS 17.0 and 27.2; on Apple TV tvOS 26.2 the three read `unsupported` and changing them fails with `setting-unsupported`. CoreSimulator numbers each option's choices from 1 and reads -1 on tvOS.

- **Problem:** `setting appearance|text-size|increase-contrast` spawns `simctl ui` to read and to write (`S:SimDriveCore/Settings/DeviceSettings.swift:38,107`). Each spawn costs hundreds of milliseconds, and listing all settings spawns three.
- **Read:** `SimDevice` has `setUIInterfaceStyle:error:` (Int), `setContentSizeCategory:error:` (Int, 1-12) and `setIncreaseContrastEnabled:error:` (Bool), with getters `currentUIInterfaceStyle`, `currentContentSizeCategory` and `currentIncreaseContrastMode` (0 unknown, 1 off, 2 on). See `N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:316-343,986-1000`. NeoSimulator's content-size numbering is in its `DeviceSettings` types (`N:NeoSimulatorKit/Devices/DeviceSettings.swift`).
- **Do:**
  1. Add these methods to `S:SimDriveNative/Simulator/SimulatorDevice.swift`, as `postDarwinNotification` is done: `NSSelectorFromString` plus `method(for:)` cast to `@convention(c)`, or ABIBridge.
  2. Map them in `SettingCatalog` in place of the `simctl ui` options.
  3. Keep `unsupported` on tvOS by checking `responds(to:)` or catching the error.
- **Test:** the matrix's `settings` section on an iPhone, iOS 17 and 27, where the probe logs the trait-collection change, and on Apple TV, where the settings stay `unsupported`. Time `setting` with no arguments before and after.

### - [x] I5. Upgrade ABIBridge from 0.19.1 to 0.20.4 (M)

**Result:** no call site needed changing, and the build has no new warnings. A cold daemon's `doctor` fell from 3.0 s to 1.6 s on an iPhone iOS 27.2, and from 3.7–5.7 s to 1.8 s on a Duo iOS 27.2; warm commands and `--no-daemon` taps are unchanged. The full matrix passes on that iPhone and Duo, and on an Apple TV tvOS 26.2.

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

### - [ ] I6. Detect a sleeping display, and wake it (M, steps 1 and 2 done)

**Result so far (2026-11-25):** steps 1 and 2 are done. `SimulatorDevice.backlights()` reads each screen's `backlight.state` and `darwinNotificationState(_:)` reads `com.apple.springboard.lockstate`; `doctor` reports them as `backlight` (per screen: `on`, `dimmed`, `off`, `unknown`) and `locked`. On an iPhone 17, iOS 27.2, the lock state matched `notifyutil -g` through a lock and an unlock; the display read `dimmed` after 20 s idle, stayed `dimmed` rather than `off` 5 s after `button lock`, and read `on` after a second press. Step 3, waking before input, is next; F29 showed a dropped tap is not always sleep, so the wake must not stand in for F29's fix.

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
  - idb finds content drawn by other processes, such as web views and pickers, by hit-testing a grid of points over the frontmost app (`I:FBSimulatorAX/Translation/AXTranslationRequest.swift:254-307`); N31's helper would see it directly.
- **Do:**
  1. Add `tree --covered`, which sets client type 2. Covered elements get `covered: true` when their frame is under an alert; compare against the frontmost read.
  2. Add `tree --app <bundle-id>`, which reads that app's process through the pid from `simctl spawn launchctl list` or the log store.
  3. Test first whether client type 2 works with the snapshot attribute.
- **Test:** the probe app needs an alert (add a button that presents one). Check `tree` and `tree --covered` with the alert up. Add unit tests for the parsing.

### - [x] I9. Say whether an error is worth retrying, and cancel abandoned requests (M)

**Result:**
- **Retry hint:** each `ErrorCode` says whether it is retryable, and failures print `"retry": true|false`. `step-failed` takes the step's answer.
- **Documentation:** the README has a table of every code with its meaning and retry answer, and `ErrorCodeDocumentationTests` fails when a declared code or its retry answer is missing from it.
- **Cancellation:** the daemon watches each client's socket while its request waits or runs, and cancels the request when the client goes away. A queued request is skipped. On iPhone 17, iOS 27.2:
  - after killing a `run` of `wait 30000`, the next command answered in 0.59 s;
  - after killing a `run` of `logs --until … --timeout 60000`, it answered in 3.95 s, while the log stream was shutting down.
- **Matrix:** the `tap`, `logs` and `misc` sections pass 57/57.
- **Not done:** the client still reads the reply with no limit, by decision. `run` and `install` legitimately take minutes, `stop` skips the queue, and cancellation frees the daemon when an agent gives up.

- **Problem:** errors carry a `code`, but an agent must know from the skill which codes are safe to retry. A client that disconnects, for example after a Ctrl-C or a timeout, leaves its request running in the daemon and blocks the next one.
- **Read:**
  - `IdentifiedFailure` categorizes errors as temporary, unavailable or io (`N:NeoSimulatorDeviceIO/IdentifiedFailure.swift:4-12`).
  - `SimulatorDeviceChannel` tells "not sent", "outcome unknown" and "no answer" apart after a deadline (`N:NeoSimulatorDeviceIO/SimulatorDeviceChannel.swift:66-111`).
  - NeoSimulator's control socket cancels a request's task when its client disconnects (`N:NeoSimulatorManager/Control/ControlSocket.swift:171-179`).
- **Do:**
  1. Add `"retry": true|false` to error JSON, from a category on each `ErrorCode` (`S:SimDriveNative/Support/SimDriveError.swift`).
  2. In `DaemonServer`, cancel the request's `Task` when the client's socket closes. Inputs must still release what they hold; `pause` already ignores cancellation.
- **Test:** unit tests for the category table. Run `logs --until never --timeout 60000` inside `run`, kill the client, and check that the next command answers at once.
- **Seen (2026-11-24, architecture review):** about 25 of Native's codes, including `coredevice-not-ready`, `coredevice-timeout`, `guest-service-timeout` and `guest-connection`, appear in neither the README nor the skill. Document them alongside the retry categories. F20 limits the calls themselves.
- **Seen (2026-11-24, F20):** `DaemonClient.exchange` still reads the reply with no limit. Every wait in the daemon is now bounded, and `stop` skips the queue, but a daemon blocked in a private call that bypasses those limits would still hang the agent's shell. Give the read a limit above the longest command limit, such as `install`'s 10 minutes, or derive it from the command.

### - [ ] I10. Apply settings through the guest's own setting actions (M, steps 1 and 3 done)

**Result so far (2026-11-25):**
- **Steps 1 and 3 are done:** `GuestSettingActions` (`S:SimDriveNative/DeviceControl/GuestSettingActions.swift`) sends the `VoiceOver` and `ColorFilter` actions straight to their guest services, with the Xcode 27.3 `executionLocation` fallback. The `coreDevice` rows now go through it, and the `devicectl` route, `DeveloperTools.devicectl` and the `devicectl` error code are gone. A refusal fails with the new `guest-setting` code.
- **Speed on an iPhone 17, iOS 27.2, warm daemon:** a read takes 30–140 ms and a change 90–370 ms, against about 3 s through `devicectl`. Listing every setting fell from about 7 s to 0.6 s.
- **Runtimes:** VoiceOver reads and changes on iOS 17.0, 26.5 and 27.2, so `voiceover` now has no minimum OS. The color filter reads on all three but changes only on iOS 27 (error 21049), so its rows keep iOS 27.
- **Checks:** the matrix's `settings` section gained read-backs of both settings, and an intensity kept across a type change. It passes 45/45 on iOS 27.2, 41/41 on iOS 26.5 and 40/40 on iOS 17.0. A change on a device without the action's service fails with `setting-unsupported`. `CoreDeviceSettingsTests` cover the inputs and outputs.
- **Not verified:** the Xcode 27.3 fallback (only Xcode 27.2 and older are installed), tvOS, the Duo, and iOS 18.

- **Problem:** most settings are a `defaults write` plus Darwin notifications. They miss side effects that the Settings app applies, and need a probe check on each runtime. CoreDevice declares guest actions that apply a setting as Settings does, and read it back.
- **Read:**
  - `N:NeoSimulatorDeviceIO/CoreDevice/GuestSettingsActions.swift:120-187` sends each action straight to the guest's Mach service, with no CoreDevice record. It finds the feature from `CoreDeviceUtilities.<Name>ActionDeclaration.executionLocation`.
  - The XPC message carries `CoreDevice.actionIdentifier`, `CoreDevice.deviceIdentifier`, `CoreDevice.invocationIdentifier`, `CoreDevice.CoreDeviceDDIProtocolVersion` = 1, `coreDeviceVersion`, and input encoded with `Mercury.XPCObjectEncoder`.
  - The actions are `Get`/`Set` + `ReduceMotion`, `ShowBorders`, `ReduceTransparency`, `VoiceOver`, `ColorFilter`, `LiquidGlassConfiguration` and `DeviceLookAndFeel` (`N:NeoSimulatorKit/Devices/SimulatorGuestSettings.swift:89-179`).
  - Look-and-feel and Liquid Glass answer error 21046 and 21035 on iOS 26; color filters change only from iOS 27 (`GuestSettingsActions.swift:31-58`, `SimulatorGuestSettings.swift:43-58`).
  - Feature identifiers include `com.apple.coredevice.feature.voiceover`, `customizeappearancesettings`, `customizeliquidglass` and `customizeuistyle`.
  - The guest connection is the one simdrive's `GuestOrientation` uses (`S:SimDriveNative/DeviceControl/GuestOrientation.swift`), and its message encoding is in `S:SimDriveNative/Guest/GuestMessageCodec.swift`.
- **Seen (2026-11-24, upstream review):** on Xcode 27.3 (CoreDeviceUtilities 699.2), `executionLocation` moved to `CoreDeviceUtilities.ActionDeclaration.executionLocation`, and NeoSimulator now falls back to it (861b9e0, `N:NeoSimulatorDeviceIO/CoreDevice/GuestSettingsActions.swift:122-136 @c9710cf`). This item needs the same fallback. N20 no longer depends on it: `devicectl device settings` covers those settings.
- **Do next (step 2):** move `reduce-motion`, `show-borders` and `reduce-transparency` to their actions (`GuestSetting` already names them), dropping their `defaults` rows rather than keeping both, once each action answers on every supported runtime; a runtime without the action keeps the whole row on `defaults`, which would mean two transports, so first check iOS 17.0 and 18. Also try `LiquidGlassConfiguration` against `glass-tint`.
- **Test:** the matrix's `settings` section on iOS 17, 18, 26 and 27, where the probe app logs each change, and once on Xcode 27.3 for the fallback.

### - [x] I11. Confirm input delivery with a guest barrier, instead of a fixed drain (S)

**Result:** `flush` now waits for the guest's barrier reply, and closing waits 300 ms after it instead of 1000 ms after the last message. As AXe found, the reply alone is not enough on iOS 27.2: closing right after it lost 20 of 20 taps on an iPhone and on a Duo, and 10 of 10 Home presses on the Duo; iOS 17.0 lost none. With 300 ms, 30 `tap --no-daemon`, 20 taps each followed by `stop`, and 10 `button home --no-daemon` all arrived on an iPhone iOS 27.2, a Duo iOS 27.2 and an iPhone iOS 17.0. On the iPhone 27.2, `tap --no-daemon` fell from 1740 ms to 1045 ms and `button volume-up --no-daemon` from 1796 ms to 1061 ms; warm taps and typing are unchanged. The full matrix passes on that iPhone and Duo and on an Apple TV tvOS 26.2; on iOS 17.0 only F16's two checks fail, as before. The barrier is not sent on open: the first flush covers activation.

- **Problem:** `GuestConnection.flush` waits on `xpc_connection_send_barrier`, which proves only that messages left the Mac's side (`S:SimDriveNative/Guest/SimulatorGuest.swift`, `flush`). Closing a connection then waits a fixed `GuestInputTiming.drain` of 1000 ms, since the guest drops messages it has not activated. A guest whose input daemon is not behind the connection drops everything silently.
- **Read:**
  - AXe sends an `isBarrier` request after each message and waits for the guest's reply (`A:Packages/IDBKit/FBSimulatorControl/HID/FBSimulatorDTUHIDTransport.swift:253-274,310-327`).
  - idb round-trips a barrier carrying key usage 0 when it opens a connection, as a liveness probe: 5 tries with a 4 s timeout, since a lookup can succeed while `dtuhidd` drops everything (`I:FBSimulatorControl/HID/SimulatorDTUHIDConnection.swift:168-242`). It drains 80 ms once per gesture, not per event (`I:FBSimulatorControl/HID/SimulatorHID.swift:88-140`).
- **Do:** add the barrier request to `GuestMessageCodec`; send it after each input and on open; drop the fixed drain where the barrier answers.
- **Test:** the cold-tap and cold-Home stress loops from I2 on an iPhone and a Duo, the full matrix, and `--timing` for `stop` and the 30 s release.

### - [ ] I12. Read the Duo's Home screen from the active panel only (M)

- **Problem:** on a Duo's Home screen, `tree` mixes both panels. Open, on iOS 27.2 (`688B6C57`), it returned 26 VoiceOver elements, 13 of them duplicates (Safari, Messages, Options, the clock), with points from -0.43 to 2.42. Closed was alike. Apps are not affected: the probe's tree is right either way.
- **Measured:** the display ID passed to `frontmostApplicationWithDisplayId:` changes nothing: 0, 1 and 3 return the same tree, open and closed, so the planned fix does not work. SpringBoard's top-level windows (open, interface 951×669 points) come in four sizes, each at the origin: the inner panel in native portrait points (669×951) and pixels (2007×2853), and the outer panel in points (466×678) and pixels (1398×2034). AXe handles three problems, all needed (`A:Packages/IDBKit/FBSimulatorControl/Commands/FBAXInactivePanelWindowFilter.swift`, `FBAXTranslationRequest.swift:357-380`):
  1. **Other panel's windows.** Dropping top-level windows at the origin with the other panel's size, in points or pixels and either orientation, removed every labelled duplicate. The panels' sizes are in the device type's `capabilities.plist` (`displays`, `integrated`, `hasDigitizer`), or in `Screens`.
  2. **Native frames.** On a quarter-turned panel, SpringBoard's windows of the panel's native size keep native coordinates. Safari's raw point (0.3656, 0.0715) matches its dock icon at (0.95, 0.52) only after AXe's conversion: x = native height − y, y = x.
  3. **Icons with the other panel's frames.** Kept windows still list some icons at the outer panel's places: Calendar reads (0.06, 0.42), drawn at (0.525, 0.43). AXe asks each button for its display (one request per button, only when step 1 dropped a window) and drops those on another.
- **Do:** the three steps in `DeviceAccessibility`, with the windows' classification in `AccessibilityLayout`, which knows the panel; the per-button display request in `SimulatorAccessibility`. **Test:** `tree` on the Home screen of a closed and an open Duo, every point against the screenshot; the probe's tree unchanged; the matrix's posture section; time `tree` on the Home screen.

### - [x] I13. Type in the runtime's keyboard layout (S, unverified)

**Result:** `type` reads the active hardware layout from the guest's keyboard preferences and inverts the runtime's `uchr` data, as AXe does, and returns the layout's name. On an iPhone iOS 27.2, German (`Grüße an @alle`, `ÄÖÜ ß € {[]}`, `é è ê`), French (`Ça va, été ? à 100 %`) and Russian (`привет`) arrived exactly; on Russian, Latin text goes as US keys, as in AXe. It is not slower: on US it loads no layout, and `type a` took 276 ms before and after, 100 characters 311–321 ms; on German `type a` took 278 ms. `key` still names US key positions, so `key a --mods cmd` is Cmd-Q on AZERTY.

- **Problem:** `type` maps characters through a US layout, failing others with `unsupported-character`. AXe types through the runtime's own hardware keyboard layout, with `type --layout` to choose one (`A:README.md:110`).
- **Do:** read how AXe resolves the layout, and map characters through it in `KeyMap`. Overlaps N12 (`keyboard-language`) and N15 (`set-value`, which avoids keys entirely).

### - [ ] I14. JSON schemas for results, and next-step hints in errors (S)

- **Read:** AXe publishes JSON Schema 2020-12 for its result envelope and each command's payload, and its errors carry `nextSteps` (`A:schemas/`, `A:README.md:48-78`). agent-device's errors carry hints and whether the action was dispatched (`D:website/docs/docs/commands.md:482`).
- **Do:** generate schemas from `CommandResults` into `schemas/`, test results against them, and add a `hint` to errors where the next step is known. Pairs with I9's retry verdicts and N26's `outputSchema`.

### - [ ] I15. Unchanged and changed trees, for fewer tokens (M)

- **Problem:** agents re-read the whole tree after each action, though most actions change a few elements.
- **Read:**
  - AXe returns a screen hash, and `describe-ui --since-screen-hash` answers "unchanged" (`A:README.md:48-78`).
  - MobileBuildMCP's snapshot rows are `ref|action|role|label|value|id`, with a hash and a 60 s lifetime (`M:src/mcp/tools/ui-automation/snapshot_ui.ts:36-107`).
  - agent-device's `--settle` returns a +/−/= diff with fresh references after an action (`D:README.md:55-75`).
- **Do:** add `hash` to `tree` results and `tree --since <hash>`, answering `{"unchanged": true}`; then `--diff` against the last tree the daemon returned. **Test:** unit tests for the hash and diff; time `tree` with and without.

### - [ ] I16. Start the accessibility server in under a second on iOS 27 (M, tried and rejected)

- **Tried (2026-11-24), not adopted:** AXe's bootstrap was implemented and measured on an iPhone 17, iOS 27.2, after F15's screen wait. It loaded XCTDaemonControl and XCUIAutomation from the selected Xcode's `SharedFrameworks`, then `connectionProviderForSimDevice:`, `requestSessionWithDaemonConnectionProvider:completion:`, `enableAutomationModeWithError:`, `loadAccessibilityWithTimeout:reply:` and `invalidate`. Three things ruled it out:
  - On a settled device it worked in 0.83 s, where no bootstrap is needed.
  - After a reboot, when it would matter, the session did not start within 5 s on three boots, nor within 20 s on another. It made the first `tree` slower: 30 s against 17–30 s without.
  - On one boot the daemon died during it, with nothing in its log.
- **Measured instead:** with F15's wait, the first `tree` after `bootstatus` took 3.1 to 30 s across five reboots. The screen wait accounts for 0–10 s of that, and the server's own start for the rest, up to about 12 s.
- **What could still work, unverified:** run the bootstrap only after the first direct read fails or comes back empty, as AXe's `readingDirectlyFirst` does. Alternatively, find what in the guest the automation session waits for after a boot (`testmanagerd`?) and start that early.

- **Problem:** the first `tree` after boot takes 14–18 s (F7).
- **Read:** on iOS 27, when a direct read fails or returns an empty tree, AXe opens an automation session through XCTest's daemon: `XCUIDeviceRemoteDaemonConnectionProvider connectionProviderForSimDevice:`, `XCUIDeviceRemoteAutomationSession requestSessionWithDaemonConnectionProvider:`, `enableAutomationModeWithError:` and `loadAccessibilityWithTimeout:reply:`, then invalidates it. It takes 0.15–0.45 s, within a 5 s limit (`A:Packages/IDBKit/FBSimulatorControl/Utility/FBSimulatorControlFrameworkLoader.m:221-433`, `A:Sources/AXe/Utilities/AccessibilityFetcher.swift:171-189`).
- **Do:** after F15's display wait, add the bootstrap as a driver in `SimDriveNative/Accessibility/`, loading `XCTDaemonControl` and `XCUIAutomation` from the selected Xcode. **Test:** the first `tree` after `bootstatus` on several boots of an iPhone and a Duo, against F7's numbers.

### - [ ] I17. Recover a stuck accessibility server without rebooting (M, needs F15's research)

- **Seen (2026-11-24):** still needs a stuck server to test against. F15's screen wait now holds back the early read thought to cause it, and the stuck state was not reproduced, so no restart was added blind. If it recurs, F15's "Research next time it happens" comes first.

- **Read:**
  - On "channel disconnected" AXe runs `simctl spawn <udid> launchctl kickstart -k user/foreground/com.apple.testmanagerd` and retries once; when SpringBoard died (zero frame, dead pid) it restarts `com.apple.CoreSimulator.bridge` (`A:Sources/AXe/Utilities/AccessibilityFetcher.swift:281-356`, `A:Packages/IDBKit/FBSimulatorControl/Commands/FBSimulatorAccessibilityCommands.swift:214-273`).
  - idb reports `springBoardRestarting` for 30 s after a restart, and reconnects its own accessibility connection when CoreSimulatorBridge restarts (`I:FBSimulatorAX/Commands/SimulatorAccessibilityCommands.swift:222-293`, `I:FBSimulatorAX/Translation/AXTranslationTransport.swift:72-198`).
- **Do:** once F15 shows which restart clears the stuck state, run it after repeated unanswered reads, once per session, and say so in the result.

### - [ ] I18. One way to wait with a deadline (M)

- **Why:** found in the architecture review (2026-11-24). Each subsystem waits in its own way, and they behave differently:
  - `Hinge.waitForAngle` polls every 100 ms for 15 s.
  - `DeviceAccessibility.becomesFrontmost` polls, but each `application()` it calls retries for up to 20 s, so `launch`'s 30 s limit can stretch to about 50 s.
  - `Screens.knownDeviceOrientation(within:)` races two tasks and leaves one reading the guest after the command returns.
  - `DeviceLogs.entry` and `events(until:)` are two stream-plus-deadline implementations, and only one of them waits for the stream to attach.
  - Native has `waitForCompletion` as well.

  Tasks left running, and `DeviceAccessibility.prepare()`'s background read, also undercut `docs/architecture.md`'s claim that a request's awaits never interleave with another's.
- **Read:** the files named above, and `S:SimDriveNative/Support/` (`waitForCompletion`).
- **Seen (2026-11-24, F20):** `DeveloperTools.collect` blocks two dispatch threads per running tool, one per pipe, so about 30 tools at once in one process exhaust the pool and stall until their limits. Reading both pipes with `readabilityHandler`, as `ToolLines` does, would block none.
- **Do:** one Core helper, `poll(every:within:)` with `withDeadline`, whose deadline also bounds the inner call and cancels what it started. Move the waits above onto it, and share `events(until:)`'s attach handling with `entry`.
- **Test:** unit tests for the helper with an injected clock. The matrix's `basics`, `posture` and `logs` sections.

### - [x] I19. Rule out missing capabilities in the driver, before CoreDevice starts (S)

**Result:**
- **Hinge check:** `CoreDeviceHinge.open` now rules out a device with one screen, using CoreSimulator's screen list in process, before it asks for the CoreDevice record. It takes the remote lazily, as the pasteboard does, and the `v68` model check is gone, leaving the decision to `supportsHingeAngle`.
- **iPhone:** `posture` right after a fresh boot answers `posture-unsupported` in 4.6 s, daemon start included, and 0.5 s warm. Before, it could wait up to 35 s on CoreDevice.
- **Reopening:** a hinge whose record stopped answering reads `hasFailed`, so the session reopens it. `LazyCapability` now closes a service it replaces, which stops the old observation; `LazyCapabilityTests` fail without that.
- **Errors:** a failed observation is rethrown from the wait instead of ending as `posture-timeout`.
- **Duo:** fresh Duos on iOS 27.2 read, close and open. On one of two first boots, under load from eight booted simulators, the first `posture open` timed out reading 0, then passed on retry; the previous build passed its one try. The matrix's `posture,misc` sections pass 18/20 on a fresh Duo; the two `openurl` failures are F27.
- **Not done:** `GuestTouchscreen.open` still opens on tvOS, and `hasTouchscreen` still decides from the runtime's name (moved to I21).

- **Why:** found in the architecture review (2026-11-24). Drivers don't follow one pattern for "the device lacks this":
  - `CoreDeviceHinge.open` needs a connected `CoreDeviceRemote` before it looks at the hardware model. So `posture` on an iPhone, iPad or Apple TV pays for starting CoreDevice (up to 30 s), and while CoreDevice isn't ready it fails with `coredevice-not-ready` instead of `posture-unsupported`.
  - Its `v68*` model check would also turn down another foldable that `supportsHingeAngle` accepts.
  - `GuestTouchscreen.open` never returns nil on tvOS; Core decides from the runtime's name (`SimulatorDevice.hasTouchscreen`) instead.
  - The pasteboard takes the remote as a lazy closure, and the hinge as a value.
  - `Hinge` calls `observe` with `try?`, so a failed observation shows up as `posture-timeout`.
- **Read:** `S:SimDriveNative/DeviceControl/CoreDeviceHinge.swift`, `S:SimDriveNative/Input/GuestTouchscreen.swift`, `S:SimDriveCore/DeviceControl/Hinge.swift`, `S:SimDriveCore/Session/DeviceSession.swift`.
- **Do:**
  - Rule out devices without a hinge from the device type or the display count, before touching CoreDevice, and drop the model check.
  - Give both CoreDevice drivers the lazy remote.
  - Return nil from `GuestTouchscreen.open` on tvOS, and delete `hasTouchscreen`.
  - Keep the observation's error and rethrow it from `waitForAngle`.
- **Test:** `posture` right after `simctl boot` on an iPhone returns `posture-unsupported` within 1 s. The matrix's `tv` and `posture` sections.
- **Seen (2026-11-24, F20):** after a CoreDevice call times out, the session reopens the remote and the pasteboard, but `Hinge` keeps its driver and its old remote. Give `Hinge` an `isUsable` that follows its remote's `hasFailed`, and have `LazyCapability` close a service it replaces, so the old observation stops.

### - [ ] I20. Unit tests for the pure logic inside I/O types, and for the daemon (M)

- **Why:** found in the architecture review (2026-11-24). The decisions most likely to regress have no unit tests, because they sit inside `@MainActor` classes that do I/O:
  - in `Screens`: whether to recalibrate or throw `stale-screenshot`, and which display a Duo's posture means;
  - in `DeviceLogs`: which cursor start wins, and `newLines` offsets and truncation;
  - `Hinge.waitUntilSettled`;
  - the drag plan in `GuestTouchscreen.drag`, which indexes out of range and kills the daemon if two paths differ in length;
  - in `KeyboardLayout`: inverting the layout, dead keys, and `UCHRValidation`;
  - the daemon: `UnixSocket` framing, `listen` refusing when a daemon is running, the stale-build replacement, and serialized requests.

  `GuestInputTests.buttonUsagesAreDistinct` wouldn't fail if a usage were wrong.
- **Read:** the types named above; `Tests/`.
- **Do:** extract `ScreenRecordPolicy`, `LogCursorStart`, a settle detector and `DragPlan` (which checks path lengths) as pure types. Add a layout fixture file for `KeyboardLayout`, a table test of button usages, and socket tests in a temporary directory.
- **Test:** prove each new test can fail by breaking the code it covers.

### - [ ] I21. Move `launch` out of `DeviceSession`, and keep private shapes in Native (S)

- **Seen (2026-11-24, I19):** `GuestTouchscreen.open` never returns nil on tvOS, and `SimulatorDevice.hasTouchscreen` decides from the runtime's name. Have the driver return nil there and delete `hasTouchscreen`, checking the matrix's `tv` section on an Apple TV.

- **Why:** found in the architecture review (2026-11-24).
  - `DeviceSession.launch` runs the whole launch: it enables app accessibility, prepares the output files, runs `simctl launch`, parses the pid, forgets screen records and waits for the app to come to the front. That is logic beyond calling a driver, while `DeviceApps` stays thin. `readAccessibility`'s error mapping belongs in `DeviceAccessibility`.
  - Native leaks a few shapes into Core:
    - `KeyboardBindings.init(runtime: ABIRuntime = .shared)` puts an ABIBridge type in its signature;
    - `SimulatorDevice.interfaceChoice` takes raw `Int`s in CoreSimulator's order;
    - `GuestOrientationReading.physical` is a raw CoreDevice string that reaches the JSON.
- **Read:** `S:SimDriveCore/Session/DeviceSession.swift`, `S:SimDriveCore/Apps/DeviceApps.swift`, `S:SimDriveNative/Input/KeyboardBindings.swift`, `S:SimDriveNative/Simulator/SimulatorDevice.swift`, `S:SimDriveNative/DeviceControl/GuestOrientation.swift`.
- **Do:**
  - Move launch and `openURL` into `DeviceApps`, with the pid parse as a pure, tested function, and the error mapping into `DeviceAccessibility`.
  - Make the runtime parameter internal, and give each setting option a typed choice.
  - Keep the `physical` JSON spelling while mapping it from an enum.
- **Test:** `swift test`; the matrix's `basics`, `tree`, `settings` and `logs` sections.

### - [x] I22. `swipe --until`: stop at the end of the content, read once the scroll rests, and slow before lifting (S)

**Result:**
- **Reads at rest:** `DeviceAccessibility.shownElementAtRest` reads the light tree until two reads in a row have the same `PlacedElement.signature` (type, identifier, label, position to a thousandth of the screen, and offscreen flag). It reads every 150 ms, up to 8 times, replacing the fixed 400 ms wait.
- **End of content:** a swipe that leaves the signature unchanged ends the command with `no-element`, naming which swipe moved nothing.
- **Resting swipe:** each swipe repeats its last point, so the finger holds still for one segment's time before lifting, and the content stops instead of flinging past the element.
- **Checks on iPhone 17, iOS 27.2:**
  - The matrix's `tap` section passes 42/42.
  - A search for a missing row now stops after 1 swipe, where it used all 10 before.
  - Scrolling back to Play lands at the top (y 0.1712), where the flinging swipe stopped short at 0.1934.
  - The signature test fails when positions are left out.
- **Not taken from AXe:** its hit-test definition of visible, which belongs to I23.

- **Why:** found in the upstream review (2026-11-24). N32 keeps swiping until `--max-swipes` runs out even when the list has already ended, reads after a fixed 400 ms however fast the content settles, and lifts the finger at full speed, so content can fling past the element. AXe has handled all of this since before `cb30a64`.
- **Read:** `A:Sources/AXe/Utilities/ScrollUntil.swift:47-92 @1ffbd35`, which judges a read once two in a row have the same tree signature (types, ids, labels and frames), and stops when a swipe changes nothing. `A:Sources/AXe/Commands/Swipe.swift:159-181 @1ffbd35`, `restingPath`, which slows the path to a stop before lifting. In simdrive: `S:SimDriveCore/Session/DeviceSession.swift` (`swipe(through:duration:until:maxSwipes:)`).
- **Do:** compare the light tree's signature before and after each swipe, and fail with `no-element` naming "reached the end" when nothing moved. Replace the fixed settle with reads until two in a row match, bounded at about 1 s. Add a resting tail to the swipe's path. AXe is GPL-3.0: reimplement, don't copy.
- **Test:** the matrix scrolls past the probe's last row and expects the end-of-content failure after 2 or 3 swipes, not 10.

### - [x] I23. `tap --label|--id`: refuse a target that a keyboard, sheet or alert covers (S)

**Result:**
- **The check:** before tapping, `DeviceAccessibility.checkReachable` hit-tests the element's tap point. `ElementSelector.hitReaches` accepts the hit only when it is in the same app and is the target, or a part of it inside its frame that is not another of the screen's light-tree elements. Otherwise the tap fails with the new `element-covered` code, naming what covers it.
- **First version too weak:** it checked frames alone and let a tap on the probe's 200×80 Glass button through, typing "g": the key fitted inside the button's frame. The rule that another light-tree element covers the target even inside its frame fixed that.
- **Checks on iPhone 17, iOS 27.2,** with the software keyboard up:
  - `tap --label "Row 1"` is refused, covered by the space bar.
  - `tap --label Glass` is refused, covered by the "g" key.
  - `tap --id play-button` taps.
  - The matrix's `tap` section, whose element taps all go through the check, passes 42/42.
- **Unit tests:** they cover a hit in another app, a key inside a large button, and a part of the target, and fail when the app check is removed.
- **Not checked:** alerts and sheets presented by the system. The rule treats a hit in another app as covering.

- **Why:** found in the upstream review (2026-11-24). The light tree can list an element under the software keyboard or a sheet, and `tap --label` then taps whatever covers it. AXe's agent mode refuses with `targetCovered` or `keyboardCovered`, and its scroll-until counts an element as visible only when a hit test at its centre finds it.
- **Read:** `A:Sources/AXe/Utilities/ScrollUntil.swift @1ffbd35` (its visibility check); in simdrive, `S:SimDriveCore/Accessibility/DeviceAccessibility.swift` (`element(at:)`, which already hit-tests a point).
- **Do:** before tapping, hit-test the element's tap point. When the hit is a different element, fail with a new `element-covered` code naming what covers it. Count the same element, or one inside it, as clear.
- **Test:** the probe's text field with the software keyboard up, then `tap --label` on a row under the keyboard.

### - [ ] I24. Send keys over the digitizer connection instead of a keyboard service (S experiment, unverified)

- **Why:** found in the upstream review (2026-11-24). AXe sends `IndigoKeyboardButtonEvent {usageCode, state}` on the same `remote.hid.digitizer` XPC connection as its touches, creating no keyboard service and using no UniversalHIDKit observer. If keys reach apps that way in simdrive too, the guest might not count a hardware keyboard as connected, which hides the software keyboard and is half the reason inputs are released after 30 s, and `GuestKeyboard` would get simpler.
- **Read:** `A:Packages/IDBKit/FBSimulatorControl/HID/FBSimulatorDTUHIDTransport.swift:188-205 @1ffbd35`, `A:Packages/IDBKit/FBSimulatorControl/HID/DTUHIDModels.swift:76-91 @1ffbd35`. `IndigoKeyboardButtonEvent` is not a type CoreDeviceUtilities exports, even on 27.2 (checked with `nm`): AXe builds that XPC dictionary by hand (`XPCEncoder`), so simdrive would have to encode it the same way, outside its ABIBridge bindings. Check that the guest still takes it on Xcode 27.3, since F28's `IndigoButtonEvent` did not survive there.
- **Do:** a spike. Send one key that way on 27.2, check that the probe logs `KEY`, and check whether the software keyboard still shows for a focused text field. Adopt it only if both answers favor it. Then record the result in `docs/private-apis.md`.

### - [ ] I26. Check VoiceOver and color filters in the matrix, and say what VoiceOver changes about input (S)

- **Problem:** left from N20 (2026-11-24). `voiceover`, `color-filter` and `color-filter-intensity` are checked only by reading back through their own actions (the matrix's `guest_action_checks`, from I10) and one screenshot, not by the probe, unlike every other setting row (AGENTS.md "Adding a capability"). With VoiceOver on, taps may select instead of activate and keys may go to VoiceOver; nothing says what still works.
- **Read:** `Evaluation/Probe` (its `STATUS` line), `Evaluation/matrix.py` (`setting_checks`), `docs/design-decisions.md` ("Settings as a catalog").
- **Do:** log `UIAccessibility.isVoiceOverRunning` and the color filter status in `STATUS`, and check the three rows in the `settings` section. With VoiceOver on, run a `tap`, a `tap --label`, a key and `type`, and record in `docs/device-behavior.md` what reaches the probe.
- **Test:** the matrix on iOS 17.0 and 27.2; VoiceOver changes on both, the color filter on 27 only.

## 3. New features

Each new command needs a `Command` case, parsing, usage text, results JSON, an error code where it can fail, parser tests, a README row and a skill line, per AGENTS.md's "Adding a capability".

### - [x] N1. `openurl <url>`: open a URL or deep link (S)

- **Why:** agents test deep links and universal links, and today must leave simdrive to do it.
- **Do:**
  - `simctl openurl <udid> <url>` through `DeveloperTools`, as `launch` does.
  - Wait for the frontmost app to change, reusing `launch`'s frontmost poll, and return `{"url", "app": {"name", "pid"}}`.
- **Test:** the probe registers a URL scheme (add `CFBundleURLTypes` to `Evaluation/Probe/Info.plist`) and logs `URL <url>` from `scene(_:openURLContexts:)`. Add a matrix check.
- **Result:** returns `{"url"}` once `simctl openurl` does, in about 1 s. Waiting for the frontmost app was dropped: a URL for the app in front changes nothing, so the wait always ran to its limit, and a cold app came forward after it. iOS asks "Open in “App”?" before a scheme's first URL; the matrix taps Open. Passes on iOS 17.0, 27.2 and the Duo.

### - [x] N2. `install <path.app|path.ipa>` and `uninstall <bundle-id>` (S)

- **Do:**
  - `simctl install <udid> <app>`. For an `.ipa`, unzip it to a temporary directory and install `Payload/*.app` (NeoSimulator uses `ditto -x -k`, `N:NeoSimulatorKit/Simulator/Import/InstallableApplication.swift:16-46`).
  - `simctl uninstall`.
  - Return the bundle ID, read from the app's `Info.plist`.
- **Test:** install and uninstall the probe app in the matrix's setup, replacing `build-probe.sh`'s own install.
- **Result:** `simctl install` takes an `.ipa` itself, so only its `Info.plist` is unzipped, for the bundle ID. `simctl uninstall` succeeds for a missing app, so `uninstall` checks first and fails with `app-not-installed`; a bad path fails with `app-invalid`. Install takes 0.7 s, uninstall 0.5 s. The matrix installs the probe with `install` and checks `uninstall`'s error; uninstalling the probe there would reset iOS's "Open in" consent, which the Duo's tree cannot show.

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

### - [x] N9. `pinch` and `rotate` gestures (S)

- **Do:** `IndigoDigitizerEvent(pointOne:pointTwo:eventType:edge:target:)` takes a second finger. simdrive passes nil (`S:SimDriveNative/Guest/GuestMessageCodec.swift:119-123`), and NeoSimulator passes it (`N:NeoSimulatorDeviceIO/CoreDevice/SimulatorGuestHID.swift:250-254`).
  - Add `GuestTouchscreen.drag(_ fingers: [(from, to)])`.
  - Add commands `pinch <x> <y> <scale> [--duration ms]` and `rotate <x> <y> <degrees>`, which compute both fingers around a center.
  - Both fingers start and end together.
- **Test:** the probe adds a `UIPinchGestureRecognizer` and a `UIRotationGestureRecognizer` that log `PINCH scale=` and `ROTATE angle=`; add matrix checks.
- **Also in:** AXe's `gesture pinch|rotate`, two-finger tap and swipe, and idb's `pinch`, over the same digitizer service.
- **Result:** `GuestTouchscreen.drag(through:and:)` moves both fingers through their own paths, so a rotation follows an arc (10° steps) rather than a chord. `TwoFingerGesture` lays the paths out in screenshot pixels, so the aspect does not skew them; the farther finger is 0.3 of the shorter side from the center. Default duration 500 ms. The probe sees scale 2 as 1.88 and 90° as 85°, since recognizers start after some movement. Passes on iOS 17.0, 27.2 and the Duo.

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
- **Seen (2026-11-24, upstream review):** on Xcode 27, AXe overrides the status bar with `xcrun devicectl device simulate statusBar override` rather than `simctl status_bar`.
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
- **Seen (2026-11-24, upstream review):** AXe's `--semantic-press` confirms the values above: request type 7, action 5, client type 2 (`A:Packages/IDBKit/FBSimulatorControl/Commands/FBAXSemanticPressGate.swift:93-110 @1ffbd35`, `FBAccessibilityElement.swift:259-271`). It also adds three things:
  - It lets the translator's bridge callback fire exactly once per press, refusing a repeat, so a press is never replayed (why it needs this is unverified).
  - It presses plain Buttons, not only CheckBoxes, for rows exposed as one Button whose centre tap misses the action.
  - It requires an accessibility identifier.
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
- **Seen (2026-11-24, upstream review):** for reading and tapping a page's controls, which covers filling forms, AXe now has a cheaper route through accessibility that works in any `WKWebView`, inspectable or not (`A:Packages/IDBKit/FBSimulatorControl/Commands/FBAXWebControls.swift:47-80,196-347 @1ffbd35`).
  - It hit-tests a grid of points 80 pt apart, starting at the centre.
  - Hits owned by `com.apple.WebKit.WebContent` (iOS attribute 3041, read with request type 2, attribute 63) are climbed through attribute 2202 to the page root, where the controls are collected.
  - simdrive's `tree` never reaches the WebContent process. Consider it as `tree --web` before the Web Inspector, which stays needed for JavaScript.
  - Its README measures a capture with the web content at 0.29 s, against 0.13 s without.
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

### - [x] N20. VoiceOver, color filters and look-and-feel settings (M)

**Result:**
- **New settings:** `voiceover`, `color-filter` (`off`, `grayscale`, `protanopia`, `deuteranopia`, `tritanopia`) and `color-filter-intensity` (0.25–1), on iOS 27 and later. They are a new `coreDevice` storage in `SettingCatalog`: `DeveloperTools.devicectl` reads them with `device info appearance|voiceover` and changes them with `device settings`, and `CoreDeviceSetting` maps between those and the setting values.
- **Intensity:** `devicectl` takes an intensity only together with a type, so setting it reads the current filter first, and fails with `setting-unsupported` when none is on.
- **Checks on iPhone 17, iOS 27.2:** each setting reads back what was set, `voiceover on|off` included, and a deuteranopia filter at 0.75 showed in a screenshot. Unit tests cover parsing the results and building the arguments.
- **Left out:**
  - `look-and-feel`: this iPhone lists only "Liquid Glass" as supported.
  - `glass-opacity`: `devicectl`'s Liquid Glass opacity read 0.5 where `glass-tint` did, so it looks like the same value (unverified beyond that).
- **Cost:** each `devicectl` call started CoreDevice afresh, about 3 s, and listing every setting went from under a second to about 7 s. I10 replaced `devicectl` with the guest's actions, sent directly: tens of milliseconds, and 0.6 s for the list. The probe does not check these settings yet (I26).

- **Seen (2026-11-24, upstream review):** I10 is no longer needed for this. AXe sets VoiceOver, the color filter with its intensity, Liquid Glass opacity, text size and contrast with `xcrun devicectl device settings appearance|voiceover`, and reads them back with `devicectl device info appearance|voiceover` (`A:Sources/AXe/Utilities/DeviceSettings.swift:92-96,242,340-341 @1ffbd35`). `devicectl device settings` exists in the installed Xcode 27. Prefer calling the CoreDevice capability behind it in process, as `pasteboard` does (unverified that it is reachable that way), and fall back to running `devicectl` through `DeveloperTools`.

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

### - [ ] N26. `simdrive mcp`: an MCP server over stdio (M)

- **Why:** agents that speak MCP but not shell get simdrive without a skill, and clients can load a few tools up front and search the rest. Neither agent-device nor MobileBuildMCP uses a Swift SDK; agent-device hand-rolls stdio JSON-RPC in a few hundred lines.
- **Read:**
  - agent-device: newline-delimited JSON-RPC on stdio; one tool per command, generated from its command registry, named as the CLI names them, flags as properties; `readOnlyHint`/`destructiveHint`; calls run one at a time, `ping` and `tools/list` never wait behind them, and `notifications/cancelled` aborts a call (`D:src/mcp/server.ts:24-128`, `D:src/mcp/router.ts:109-146`, `D:src/mcp/command-tools.ts:143-236`).
  - Small context: a 2 KB `instructions` card, an MCP-only `help` tool serving the CLI's help topics, `_meta["anthropic/alwaysLoad"]` on the loop tools only (open, snapshot, press, fill, scroll, back, wait) and `anthropic/searchHint` on the rest (`D:src/mcp/server-guide.ts:13-90`).
  - Device and configuration come from the environment, never from tool arguments (`D:src/mcp/tool-control-fields.ts`).
  - MobileBuildMCP returns screenshots as base64 JPEG image blocks, 800 px at quality 75, and file paths from its CLI; session defaults remove `simulatorId` from every schema (`M:src/mcp/tools/ui-automation/screenshot.ts:233-341`, `M:src/utils/typed-tool-factory.ts:154-159`).
- **Do:**
  1. `simdrive [<udid>] mcp` serves `initialize`, `tools/list`, `tools/call`, `ping` and cancellation on stdio, sending each call through the device's daemon as the CLI does.
  2. Generate tools from `Command` and the usage text, with a JSON Schema per command; mark reads read-only and settings, launch and pasteboard writes destructive. The pasteboard write stays behind an explicit argument, per AGENTS.md.
  3. Always load `tree`, `tap`, `type`, `key`, `swipe`, `screenshot` and `launch`; serve SKILL.md's sections from a `help` tool and its gist as `instructions`.
  4. `screenshot` returns an image block, downscaled, with the path; other results return their JSON as text and `structuredContent` (I14's schemas as `outputSchema`).
  5. The device comes from the argument or `SIMDRIVE_UDID`, or the only booted simulator.
- **Test:** unit tests for the JSON-RPC framing and the tool schemas; a scripted session against a booted simulator; add the server to Cursor's and Claude Code's MCP configuration and drive the probe. Document the setup in the README and skill.

### - [x] N27. Target elements by label or identifier: `tap --label|--id`, `wait`, `scroll --until` (M)

**Result:**
- **What landed:** `tap --label|--id [--timeout ms]` and `wait --label|--id [--absent] [--timeout ms]`.
- **Selection:** `ElementSelector` picks the one onscreen light-tree element whose label or identifier matches exactly. `AccessibilityLayout.placedElements` now builds both the light tree and these lookups, so they place elements identically.
- **Errors:** new codes `ambiguous-element`, `element-offscreen` and `element-still-shown`; none in time is `no-element`. Both commands wait 5000 ms by default, as `logs --until` does.
- **Checks:** parser and selection tests, the latter shown to fail when offscreen matches count. The matrix's `tap` section, with new checks for `tap --id`, a `run` of `tap --label` and `wait --label`, both timeouts and an offscreen row, passes 38/38 on iPhone 17, iOS 27.2.
- **Not done:** `swipe --until`, which moved to N32. Not run on a Duo, iPad or Apple TV.

- **Why:** agents read the tree, then copy a point into `tap`; one call that resolves the element, and waits for it, removes a round trip and a race. Complements N15, which acts through accessibility instead of touches.
- **Seen (2026-11-24, app_mono):** saved `run` step files can only tap fixed points, so a check written as `["tap 0.1977 0.1192", …]` breaks when a sidebar resizes; with `tap --label View` the same file survives layout changes. Inside `run`, there's no way to feed one step's `tree` result into the next.
- **Read:**
  - AXe: `tap --id|--label|--value` with `--element-type`, `--wait-timeout` and `--poll-interval`; `gesture scroll-* --until-id|--until-label --max-swipes` and `--inside-id` (`A:README.md`).
  - agent-device: selectors (`id=`, `label=`, `role=`) and refs (`@e12`) for every action; `wait text|@ref|selector|absent`; `scroll --until`, with typed failure reasons (`D:website/docs/docs/commands.md:442-470,580`).
  - MobileBuildMCP taps a ref by identifier, then label, then value when that is unique, else at its activation point (`M:src/mcp/tools/ui-automation/shared/semantic-tap.ts:67-130`).
- **Do:** resolve the element from a light tree in `DeviceAccessibility` and tap its point; `wait --label|--id [--absent] [--timeout ms]`; `swipe --until-label|--until-id --max-swipes n`. Ambiguous matches fail with a new code listing the candidates.
- **Test:** parser tests; matrix checks on the probe's labelled buttons and its scrolling list.

### - [ ] N28. `record start|stop`: video from the framebuffer (M)

- **Read:** idb wraps the framebuffer IOSurface in a `CVPixelBuffer` and encodes H.264 or HEVC with VideoToolbox, pushing a frame only when the simulator renders one (`I:FBSimulatorVideo/README.md`). AXe encodes a screenshot per frame with `AVAssetWriter` (`A:Sources/AXe/Commands/RecordVideo.swift:153-200`). agent-device uses `simctl io recordVideo` and can overlay touches (`D:packages/platform-apple/src/recording/runtime.ts:39`).
- **Seen (2026-11-24, upstream review):** AXe's `record-video` still encodes a screenshot per frame, but its new Mirror registers as a framebuffer surface consumer and encodes HEVC with `VTCompressionSession` (`A:Sources/AXe/Mirror/MirrorSession.swift:33,114-134,326-352`, `A:Packages/IDBKit/FBSimulatorControl/Framebuffer/FBFramebuffer.swift:34-157 @1ffbd35`). That is the better reference for the framebuffer route.
- **Do:** start with `simctl io recordVideo` stopped by SIGINT, as Not planned describes; move to the framebuffer surfaces simdrive already reads (I7) if `simctl` is slow to start or misses the Duo's panels. The daemon owns the recording, so it survives between calls.
- **Test:** record a matrix tap sequence on an iPhone and a Duo; check duration and frames with `ffprobe`.

### - [ ] N29. `alert`: read, accept and dismiss system alerts (M, needs I8)

- **Read:** agent-device's `alert get|wait|accept|dismiss` ranks localized button labels (`D:website/docs/docs/commands.md:473-484`). idb detects modals from `SBAlertItemWindow` and `_UIAlertController*` windows (`I:SimulatorFrameworkBridge/Swift/AccessibilityService.swift:162-165,785-820`).
- **Do:** after I8 reads SpringBoard, find an alert's buttons in its tree and tap them by label; `alert` returns the title, message and buttons, or null.
- **Test:** the probe requests a permission at launch; accept and deny it in the matrix.

### - [ ] N30. Install simdrive with Homebrew, and the skill with `simdrive init` (M)

- **Read:** AXe ships `brew install cameroncooke/axe/axe`; the formula ad-hoc signs the binary and frameworks after install, and CI signs and notarizes releases (`A:scripts/generate-homebrew-formula.sh:62-91`, `A:.github/workflows/release-shared.yml:151-269`). The skill is embedded in the binary, and `axe init` installs it; Claude and Codex plugin manifests sit in `A:agent-plugin/`.
- **Do:** a tap with a formula building from source with Xcode 27; `simdrive init [cursor|claude|<dir>]` writing the skill with this binary's path in place of `<simdrive>`, replacing the manual steps in AGENTS.md.

### - [ ] N31. An in-guest accessibility helper (L, unverified)

- **Why:** reading through `AXPTranslator` costs a round trip per element, sees only the frontmost app, and depends on the guest's accessibility server (F7, F15).
- **Read:**
  - idb's `axbridge` backend runs a helper inside the guest, reached over a Unix socket. It returns the whole tree in one round trip, sees content drawn by other processes, asserts automation mode, and reports modals (`I:FBSimulatorAX/README.md:15-100`, `I:SimulatorFrameworkBridge/`).
  - agent-device compiles a helper with `xcrun --sdk iphonesimulator clang`, starts it with `simctl spawn <udid> … serve <socket>`, and snapshots through `XCTAccessibilityFramework`'s `userTestingSnapshotForElement:`: warm snapshots take 8.6–118 ms (`D:apple/snapshot-bridge/README.md:10-24`, `D:docs/evidence/ios-snapshot-adr-0004-measurements-2026-11-06.md:25-27`).
- **Do:** prototype the helper as a separate target built for the simulator SDK, spawned by the session; compare speed, coverage and failure modes with the translator before switching `tree` to it.

### - [x] N32. `swipe --until-label|--until-id --max-swipes n`: scroll an element into view (S, needs N27)

**Result:** `swipe … --until-label|--until-id [--max-swipes N]` reads the light tree first, then swipes, waits 400 ms for the scroll to settle and reads again. It stops at the first read where one onscreen element matches, returning `{"element", "swipes"}`, or fails with `no-element` after `--max-swipes` (10 by default). It takes no `--edge` or `--display`. The matrix's `tap` section scrolls the probe to its last row (2 swipes) and back to Play (1), and passes 40/40 on iPhone 17, iOS 27.2.

- **Why:** split from N27. `tap --label` fails with `element-offscreen` for a row scrolled out of view, and the agent must then swipe and reread the tree by hand.
- **Read:** N27's sources (AXe's `gesture scroll-* --until-id`, agent-device's `scroll --until`); `S:SimDriveCore/Accessibility/ElementSelector.swift` (`isShown`), `S:SimDriveCore/Accessibility/DeviceAccessibility.swift` (`element(_:within:)`).
- **Do:** repeat the swipe, then read the light tree, until the selector is shown or `--max-swipes` runs out; fail with `no-element` naming how many swipes ran. Return the element, as `wait --label` does.
- **Test:** parser tests; the matrix's `tap` section scrolls the probe's list until its last row is on screen.

## Not planned

- **Scroll wheel and trackpad gestures:** the guest drops them unless they come from a real Mac HID device (`N:NeoSimulatorPresentationAdapters/Native/CoreDeviceScreenInput.swift:318-319,388`). Drags already scroll.
- **NeoSimulator's control-socket CLI (#619):** it offers only `logins` and `sign-in`, and needs the NeoSimulator app running. N25 covers its use.
- **Screen connection, USB capture, virtual-machine client and device reports:** these serve physical devices (`N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceScreenConnection.swift`, `RemoteScreenCaptureSource.swift`, `CoreDeviceVirtualMachineClient.swift`, `N:NeoSimulatorKit/Devices/DeviceReports.swift`). `logs` already reads simulator crash reports.
- **Video recording through CoreDevice:** `simctl io recordVideo` covers simulators. N28 plans `record start|stop` over `simctl` (stopped with SIGINT, waiting for "Recording started", as `N:NeoSimulatorKit/Simulator/Capture/VideoRecording.swift:56-96` does).
- **An XCTest runner inside the simulator, as agent-device uses:** each touch costs 0.7–3.7 s, and a cold start may build the runner with `xcodebuild` (`D:apple/runner/RUNNER_PROTOCOL.md`, `D:docs/evidence/ios-other-paths-latency-2026-10-19.md`). simdrive's guest services answer in milliseconds.
- **An LLM agent loop, React Native tooling, device clouds and physical devices** (AXe's `agent`, agent-device's `react-devtools` and remote sessions): outside simdrive's job of driving simulators for an agent that already exists.
- **External displays, CarPlay and audio routing:** costly, and of little use to agents.
