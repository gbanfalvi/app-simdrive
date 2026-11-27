# Completed

Items from [backlog.md](backlog.md) that have landed, each with its **Result:**, under the section and ID it had there. The backlog's Conventions apply: IDs are never reused, and `S:`, `N:` and `A:` paths are at the commits it names. What was learned is also in [docs/](../docs).

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

### - [x] F16. A bottom-edge swipe does not go home on a new iPhone iOS 17.0 (S)

**Result (2026-11-25):** iOS 17.0's guest ignores a touch's edge. On a new iPhone 15, iOS 17.0, Xcode 27.0, backboardd logs the swipe as `swipe-locked; behavior: foreground` and delivers it only to the app, which scrolls; on iOS 18 and later the same touch is marked `sgp` and also reaches SpringBoard's system gesture window. A start at 0.995, 0.999 or 1.0, a 600 ms swipe, a reboot and a build from before F17 (`06a136b`) all failed alike, and NeoSimulator sends the edge the same way, so nothing in simdrive's sending changed it. `button home` goes home and unlocks. The matrix now expects the swipe to stay in the app below iOS 18, so it fails if a runtime starts honoring edges, and unlocks with Home there; buttons 12/12 on that simulator. Documented in `docs/device-behavior.md`, the README and the skill. Not done: whether 17.1–17.5 behave alike (none installed), and failing `swipe --edge` with an error code on iOS 17 instead of returning `ok`, a contract change to decide with the user.

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

### - [x] F29. A tap during a system alert's present transition is dropped, though it returns `ok` (M)

**Result (2026-11-25):** option 2, chosen with the user. `tap --label`/`--id` sample the 44 points around the tap point from the framebuffer every 25 ms (`SimulatorDevice.screenPixels`, copying only those rows) and tap once they have not changed for 150 ms (`Stillness`), or after 1.5 s; the result reports `"settle": {"waited", "still"}`, null without a readable framebuffer. The matrix no longer sleeps before tapping the URL alert. New simulators, no sleep: iPhone 17 iOS 27.2 `tree,keys,misc` 45/45 (the alert tap waited 548 ms) and the whole matrix 132/132; iPhone 15 iOS 17.0 `tree,tap,misc` 49/49 (548 ms); iPhone Duo iOS 27.2 121/124, the alert at 201 ms and every element tap passing, with three failures outside taps that passed alone (F30). Element taps on a still screen waited 162–201 ms. Left: I27, then I28.

- **Problem:** found after F27 (2026-11-24), first filed as I25. Without the matrix's 1 s sleep before `tap --label Open`, the full matrix on a new iPhone 17, iOS 27.2, fails `openurl from-home` and `openurl in-front`, and the alert left up then fails 8 later checks: 120/130 with v0.1.0. The matrix keeps the sleep; an agent that taps an alert as soon as `tap --label` finds it hits the same drop, and so does one that taps during an app's own transitions (the skill already says to wait about 1 s after them).
- **Cause (2026-11-25):** SpringBoard ignores interaction events while it presents the alert. In SpringBoard's and backboardd's debug logs, backboardd hit-tests the touch to the alert's context correctly, but SpringBoard's UIKit logs `Evaluating dispatch … tagged context: <alert>; shouldSend: 0; ignoreInteractionEvents: 1` and drops it, until the present transition ends ("Alert layout appears correct"). Tapping the alert's point every ~100 ms from `openurl` on a new simulator: taps at +352 and +418 ms after "Received request to activate alertItem" were ignored, layout was correct at +568 ms, and the tap at +619 ms opened the URL. A second `openurl` with the alert still up presents it again (the `in-front` drop), with the same window (layout correct at +470 ms, a tap at +240 ms ignored). Recorded in `docs/device-behavior.md`.
- **Why it looked like it needed the earlier sections:** the earlier single-step script slept 1.5 s before tapping, which is the workaround, so its passes meant nothing. A bisect with no sleep (`setting full-keyboard-access off` then focusing the text field reproduces; either alone or in the other order does not; the key presses and `type` are irrelevant) only changes when `openurl` returns relative to the alert. When `openurl` took 3 s, the alert had settled before the tap; when it returned first, `tap --label` found the alert in the tree at once and tapped inside the window. With FKA off and the field focused, waiting 1 s after the alert appeared delivered both taps.
- **Ruled out earlier:** the alert's accessibility frame, which is final from the first read (I25's frame-rest wait, backed out); display sleep and lock (`doctor` read `on` and unlocked at every drop); the idle input release. One earlier observation was not reproduced: on a kept simulator a first `tap --label Open` minutes after the alert appeared was dropped; on another, minutes later and with a new daemon, the first tap went through.
- **Fix options, to decide with the user (they change `tap`'s timing):**
  1. **Docs only:** the skill and README say to wait for the transition (they already do, generally); keep the matrix's sleep. No cost, no fix.
  2. **Wait for the target to look still:** `tap --label`/`--id` compares the element's frame region in two framebuffer copies (in-process since I7) a short interval apart, until alike or a bound (about 1 s), and reports how long it waited. Covers alerts and app transitions alike; costs at least one interval on every element tap; can't help coordinate taps; content that keeps animating (a spinner, a blinking cursor) hits the bound.
     - **Spike (2026-11-25, iPhone 17, iOS 27.2, two new simulators):** a throwaway target sampled the Open button's region through `SimulatorDevice.screenFrame` every ~25 ms while the alert presented, counting pixels whose RGB moved by more than 6 in total. Relative to "Received request to activate alertItem": still until +121 / +105 ms (nothing drawn yet), nearly every pixel changing until about +300 ms, then 0.5–4% per sample until +540 / +508 ms, and no change after. SpringBoard's "Alert layout appears correct" came at +520 / +494 ms, and the measured ignore window ended between +418 and +619 ms, so "the element's pixels stopped changing" tracks the window to within about one sample. The tree first showed Open at +169 ms in the second run.
     - **Design this suggests:** require the element's region to be unchanged for at least 150 ms, longer than the ~120 ms before the first frame is drawn, in case the tree finds the element that early. Bound the wait at about 1.5 s and tap anyway, reporting the wait in the result. Each sample cost ~12 ms, mostly copying the whole 12 MB surface; copying only the element's rows from the locked surface should make that negligible. On a still screen this adds about 150 ms to every `tap --label`/`--id`.
     - **Not measured:** app transitions (a navigation push, a sheet), the alert's dismissal, landscape and other devices, and whether a 150 ms stillness ever passes in the middle of a transition.
  3. **Read the ignoring state:** find a private signal for SpringBoard's or the app's `isIgnoringInteractionEvents` (accessibility attributes, a SpringBoard service). Precise if one exists; none is known.
- **Reproducing:** iOS asks only for a scheme's first URL on a simulator, so each try needs a new one. With SpringBoard's `EventDispatch` and `AlertItems` log categories streaming, open the probe URL with the probe in front, after warming the daemon with a tap elsewhere, and tap `0.6841 0.5423` in a loop; each touch's `ignoreInteractionEvents` value and its offset from the activation give the window.

### - [x] F30. The matrix fails `logs` and `settings restored` on a Duo when another simulator runs a matrix at once (S)

**Result (2026-11-25):** both failures came from slow reads reported as permanent ones. `DeviceSettings` read each guest setting action with `try?`, so a `guest-service-timeout` under load read as `unsupported`; it now reads `unsupported` only when the guest lacks the action's service or refuses it (a non-retryable error), and a retryable failure fails the read, which `setting_snapshot` already runs again. `log stream` not starting within 5 s now fails with the retryable `tool-timeout` rather than `log-read`, which stays for a stream that ends before starting. With both, `--only logs,settings` passed 76/76 on a new iPhone 17 and a new Duo, iOS 27.2, run at once; the flake did not recur there, so that the fix catches it is unverified. Not done: the matrix does not run a retryable `run` step again, so `run --logs` can still fail under heavy load.

- **Problem:** on a new iPhone Duo, iOS 27.2 (2026-11-25), running the whole matrix while a new iPhone 17 ran its own, `run --logs attributes the tap` and `logs --until in run` failed with `step-failed` ("log stream did not start within 5 s"), and `settings restored` reported `{'voiceover': False}`. `--only logs,settings` on the same simulator then passed 76/76.
- **Guess:** load. The log stream's 5 s start limit is too short with two simulators busy. `setting_snapshot` may have read VoiceOver as unsupported at first (`DeviceSettings` maps a failed action read to unsupported), so the restore compared unsupported with off.
- **Do:** run two matrices at once again and capture the first `setting voiceover` response and the log stream's start time. If load explains both, make the snapshot retry an action read that failed with a retryable error, and decide whether the 5 s limit should grow or the error should say `retry`.

### - [x] F32. A repeated crash leaves no report of its own, so `logs` misses it, and the matrix's crash check fails (M)

**Result (2026-11-25):** `logs` now also finds crashes in SpringBoard's FrontBoard line for an app that ends on a signal, `[app<bundle-id>:pid] Process exited: … domain:signal(2) code:SIGTRAP(5)` (iPhone 17, iOS 27.2), which is logged whether or not ReportCrash writes a report; a relaunch or quit ends in the runningboard domain, and SIGKILL and SIGTERM are left out as terminations. A plain `logs` read asks for those lines in its existing `log show`, OR'd into its predicate and split out before the entries are digested (about 0.2 s more: 1.4 s against 1.2 s); `--source crash` alone runs one exit-only `log show`; `--until` reads keep to reports. A crash known only from the log has `"path": null`, no frames and its signal as `exception`, and one with a report is listed from the report (deduplicated by pid). `CrashReportsTests` and `LogQueryTests` cover the parsing, the deduplication and the predicate. On a simulator whose probe crashes were all repeats, the matrix's `logs` section passed 35/35 with the crash from the log. Step 2, reading the `Multiple` attribute, was not done: the log finds every crash, and a folded report may be another device's, so its frames could mislead. Also fixed on the way: `IdleReleaseTests` waited a fixed 200 ms, which the whole suite, now starting 80 tools at once (I18), could outlast.

- **Problem:** found with I18 (2026-11-25). The Mac's ReportCrash writes no new report for a repeat of the same crash, wherever it happened. On a new iPhone 17, iOS 27.2, the probe's `-probeCrash` wrote nothing because another simulator's matrix had crashed it at 15:25. The matrix's fallback, `logs --peek --source crash --since 24h`, then finds nothing, since `logs` rightly keeps only this device's reports, and `logs crash summary` fails. An agent's app crashing twice the same way hits the same gap: `logs` reports no crash.
- **How repeats are recorded (2026-11-25, source comparison, checked here):** ReportCrash folds a repeat into an earlier report without touching its JSON: it sets the file's extended attribute `Multiple` (a little-endian UInt16 count, with a `Signature` SHA-1 beside it) and moves the file's modification time to the repeat. The repeat can land on another device's report, so filtering by `coalitionName` cannot attribute it (`docs/open-questions.md`).

### - [x] F33. Unanswered accessibility requests queue in the guest and may wedge it (S)

**Result (2026-11-25):** `AccessibilityChannel.send` now waits at most 5 s for one request, within its read's deadline, and keeps one request in flight per device through `RequestGate`: a request that goes unanswered stays in flight until the guest answers it, however late, and the next request waits for that instead of queueing behind it in CoreSimulatorBridge. A read retries after an unanswered request until its 20 s deadline, which the gate makes safe, so a first read after boot still gets its time. `accessibility-timeout` names how many requests are still unanswered. The race between a late answer and the sender giving up is settled per request under a lock. `RequestGateTests` cover waiting, giving up at a deadline and late answers. Cold, on new simulators, iOS 27.2: iPhone 17 `tree,tap` 56/56, Duo `tree,posture` 35/35. Not shown: that this prevents F15's wedge, which was never reproduced; I17 holds the recovery leads.

- **Problem:** found in the source comparison (2026-11-25), checked in simdrive's code. CoreSimulatorBridge answers accessibility requests one at a time, and a request whose wait times out is not withdrawn, so everything sent later waits behind it; idb counts these per simulator and tags later reads `behindAbandoned` (`I:FBSimulatorAX/README.md:155-178`, `I:Translation/AXTranslationTransport.swift:72-152,201-243`). `AccessibilityChannel.send` (`S:SimDriveNative/Simulator/SimulatorDevice.swift`) waits until the read's whole 20 s deadline, and a session's background warm-up read can leave an unanswered request behind for the next read. A plausible cause of F15's wedged Duo.
- **Do:** cap each request at about 5 s, as idb, AXe and NeoSimulator do (`A:FBAXTranslationRequest.swift:36`, `N:NeoSimulatorDeviceIO/DeviceOperationPolicy.swift:71`); count abandoned requests per device and send no new one while one is outstanding; name them in `accessibility-timeout`.

### - [x] F24. Sessions share the accessibility translator, but each brings its own bridge and read state (M)

**Result (2026-11-25):** `TranslationHub` owns the process's `AXPTranslator`: it sets the delegate once, runs every read on one serial queue, and its `AccessibilityDispatcher` routes each request through a locked `TokenRegistry` to the registering session's channel and read state; a token no session holds gets no request sent. A token per read, as upstream suggests, does not work here: with `<udid>/<UUID>` SpringBoard's frontmost element read with an empty frame on iOS 27.2, so `tree` on the Home screen failed with `accessibility-translation` while apps read fine (the matrix's `tree home screen` caught it). The token stays the UDID; a session opened after a reboot replaces the route, and a closing session removes it only while it is still its own. `translationApplicationObjectForPid:` asks its delegate with a nil token, which crashed a debug build through the non-optional parameter and, in release, found no route (`tree --app` failed with `app-not-running`); the delegate now takes optional tokens and sends a tokenless request to the only registered session. On a new iPhone 17, iOS 27.2, `tree` answered before and right after a reboot under the same daemon, with the new SpringBoard's pid, and a reboot while `tree` looped through the daemon for 70 s gave 347 answers and 4 `not-booted` while it was down, nothing else. The matrix's `tree,tap` passed on a new iPhone 17 (56/56) and a new Duo (55/55), and the whole matrix on the iPhone otherwise. Not run: Thread Sanitizer.

- **Problem:** found in the architecture review (2026-11-24). `AXPTranslator.sharedInstance` has one `bridgeTokenDelegate`, but each `SimulatorAccessibility` has its own queue, `AccessibilityBridge` and `AccessibilityRead`. After a reboot, the daemon opens a new session, whose `prepare()` replaces the delegate while the old session's read, which can take up to 20 s, still runs on its own queue. That old read then goes through the new bridge, under the new read's deadline, and writes its failure into the new read from another thread: a data race on an `@unchecked Sendable` object.
- **Read:** `S:SimDriveNative/Accessibility/SimulatorAccessibility.swift` (`open`, `init`, `AccessibilityBridge`, `AccessibilityRead`), `S:SimDriveCore/Daemon/DaemonServer.swift` (`openSession`).
- **Do:** give the translator, its bridge and one serial queue a single owner for the whole process. Keep each read's state per request, keyed by the token the callbacks already receive.
- **Test:** reboot a simulator you created while `tree` runs in a loop through the daemon, then check that the next `tree` answers; run once with Thread Sanitizer (`swift build -c release --sanitize=thread`).
- **Seen (2026-11-25, source comparison):** AXe and idb set one process-wide dispatcher as `bridgeTokenDelegate` once, with a locked token → request registry; each read gets its own UUID token and timeout, and unknown tokens get `AXPTranslatorResponse.empty()` (`A:FBSimulatorAccessibilityCommands.swift:29-38`, `A:FBAXTranslationDispatcher.swift`). idb also runs every translator call on one process-wide serial queue, because concurrent use over-released token storage and crashed (`I:FBSimulatorAX/.../AXTranslationDispatcher.swift:38`). CoreSimulator forwards bridge notifications to `-[AXPTranslator handleNotification:…]` on its own queue, a second thread touching the translator (`I:AXTranslationTransport.swift:41-45`). NeoSimulator avoids the translator: it builds `AXPTranslatorRequest`s itself (types 4 frontmost, 5 attributes, 6 hit test, 7 action, 8 set) and sends them with `sendAccessibilityRequestAsync` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:386-500`). So: a token per read instead of the UDID, one owner and queue per process, per-read state looked up by token.

### - [x] F31. The matrix fails a check on a retryable error right after a first boot (S)

**Result (2026-11-25):** `sd()` runs a command once more when its response says `retry`, prints a `RETRY` line with the first error, and keeps the first code in the response's `retried`. Commands whose second run could act twice are not retried (`ACTING_COMMANDS`: input, buttons, push, shake, memory warnings, `run`, pasteboard writes, `split`, and `alert accept|dismiss`), nor `--timing` runs; no check expects a retryable code. `setting_snapshot`'s own retry went. Checked with a wrapper that failed the first `setting` read with `tool-timeout`: the matrix printed the retry and the section passed it. Not done: the causes upstream points at in simdrive itself (a young `dtuhidd`, launchd's error 124), which stay retryable errors; they are in the notes below for whoever takes them on.

- **Problem:** found with N6 (2026-11-25). On a new iPhone 17, iOS 27.2, booted while another new simulator booted, `setting bold-text on` failed with `tool-timeout` ("simctl spawn did not finish within 60 s") and the section went 46/47; rerun on the same simulator, 47/47. The first `simctl push` after a boot also takes ~52 s (N11). `setting_snapshot` already runs a read again when it says `retry`, but other checks do not, so a slow first boot fails checks that would pass.
- **Causes found upstream (2026-11-25, source comparison), which make some of these fixable in simdrive rather than retried by the matrix:**
  - **The digitizer's daemon is not up yet.** `dtuhidd` starts on demand; early in a boot it asks CoreAnimation for displays, aborts when none is up, and launchd throttles its respawn for 10 s, while the service lookup still returns a port and every send is dropped. idb probes a fresh connection with a barrier, 4 s per attempt, 4 s backoff, 5 attempts, a new lookup each time, and measured a daemon answering about 19 s after boot, past simdrive's 10 s `guestServiceLimit` (`I:FBSimulatorControl/HID/SimulatorDTUHIDConnection.swift:14-37,72-121`). AXe waits until `launchd_sim` has been up 10 s and `dtuhidd` is its child, and found that reconnecting on a long-running simulator made input worse, so it retries once at most (`A:Sources/AXe/Utilities/HIDBrokerReadiness.swift:51-60`, `A:docs/release-readiness.md:100`). For simdrive: in `GuestTouchscreen.open`, retry an opening barrier that times out only while the boot is young (or no `dtuhidd` runs), with a short timeout, a backoff and a fresh lookup; keep the single 10 s wait otherwise. idb also pays a ~200 ms "device-open tail" after the first barrier before handing out the connection (`:174-182`), likely F17's 215 ms.
  - **launchd_sim refuses work around a boot.** It answers error 124 ("Domain is tearing down") for a few seconds; NeoSimulator retries after 1, 2, 4 and 8 s (`N:NeoSimulatorKit/Devices/BackgroundServices.swift:354-355,556-562`). Recognize it in `DeveloperTools.simctl` as a fast retryable error. Its notes that disabling `nanoregistryd` "hangs every simctl operation" (`:303-311`) are a candidate for the 60 s `simctl spawn` hangs (unverified).
  - **Preferences can be read without the guest.** I30 reads them from the host's plist, which would end the `setting` read timeouts.
- **Seen (2026-11-25, I18):** on a new iPhone 17, iOS 27.2, the first `tap` and `tap --no-daemon` failed with `guest-service-timeout` on the digitizer, and on a new Duo `posture half` with `posture-timeout` reading 0.0. Both sections passed on the same simulators rerun, and `posture` on a second new Duo.
- **Do:** in `sd()` (`Evaluation/matrix.py`), run a command once more when its response has `"retry": true`, and mark the check's detail with the first error so a retry stays visible rather than hidden. Leave commands whose retry changes the outcome, such as taps, to the check itself.
- **Test:** `Evaluation/fresh.py --only settings` on two new simulators booted at once.

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

### - [x] I11. Confirm input delivery with a guest barrier, instead of a fixed drain (S)

**Result:** `flush` now waits for the guest's barrier reply, and closing waits 300 ms after it instead of 1000 ms after the last message. As AXe found, the reply alone is not enough on iOS 27.2: closing right after it lost 20 of 20 taps on an iPhone and on a Duo, and 10 of 10 Home presses on the Duo; iOS 17.0 lost none. With 300 ms, 30 `tap --no-daemon`, 20 taps each followed by `stop`, and 10 `button home --no-daemon` all arrived on an iPhone iOS 27.2, a Duo iOS 27.2 and an iPhone iOS 17.0. On the iPhone 27.2, `tap --no-daemon` fell from 1740 ms to 1045 ms and `button volume-up --no-daemon` from 1796 ms to 1061 ms; warm taps and typing are unchanged. The full matrix passes on that iPhone and Duo and on an Apple TV tvOS 26.2; on iOS 17.0 only F16's two checks fail, as before. The barrier is not sent on open: the first flush covers activation.

- **Problem:** `GuestConnection.flush` waits on `xpc_connection_send_barrier`, which proves only that messages left the Mac's side (`S:SimDriveNative/Guest/SimulatorGuest.swift`, `flush`). Closing a connection then waits a fixed `GuestInputTiming.drain` of 1000 ms, since the guest drops messages it has not activated. A guest whose input daemon is not behind the connection drops everything silently.
- **Read:**
  - AXe sends an `isBarrier` request after each message and waits for the guest's reply (`A:Packages/IDBKit/FBSimulatorControl/HID/FBSimulatorDTUHIDTransport.swift:253-274,310-327`).
  - idb round-trips a barrier carrying key usage 0 when it opens a connection, as a liveness probe: 5 tries with a 4 s timeout, since a lookup can succeed while `dtuhidd` drops everything (`I:FBSimulatorControl/HID/SimulatorDTUHIDConnection.swift:168-242`). It drains 80 ms once per gesture, not per event (`I:FBSimulatorControl/HID/SimulatorHID.swift:88-140`).
- **Do:** add the barrier request to `GuestMessageCodec`; send it after each input and on open; drop the fixed drain where the barrier answers.
- **Test:** the cold-tap and cold-Home stress loops from I2 on an iPhone and a Duo, the full matrix, and `--timing` for `stop` and the 30 s release.

### - [x] I13. Type in the runtime's keyboard layout (S, unverified)

**Result:** `type` reads the active hardware layout from the guest's keyboard preferences and inverts the runtime's `uchr` data, as AXe does, and returns the layout's name. On an iPhone iOS 27.2, German (`Grüße an @alle`, `ÄÖÜ ß € {[]}`, `é è ê`), French (`Ça va, été ? à 100 %`) and Russian (`привет`) arrived exactly; on Russian, Latin text goes as US keys, as in AXe. It is not slower: on US it loads no layout, and `type a` took 276 ms before and after, 100 characters 311–321 ms; on German `type a` took 278 ms. `key` still names US key positions, so `key a --mods cmd` is Cmd-Q on AZERTY.

- **Problem:** `type` maps characters through a US layout, failing others with `unsupported-character`. AXe types through the runtime's own hardware keyboard layout, with `type --layout` to choose one (`A:README.md:110`).
- **Do:** read how AXe resolves the layout, and map characters through it in `KeyMap`. Overlaps N12 (`keyboard-language`) and N15 (`set-value`, which avoids keys entirely).

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

### - [x] I27. Check the settle wait of element taps on app transitions (S)

**Result (2026-11-25):** the probe takes `-probeSheet` (an animated page sheet) and `-probePush` (an animated navigation push), each showing a Done button that logs `TAP done <name>`. The matrix's `tap` section launches with each three times and runs `tap --label Done` at once. On a new iPhone 17, iOS 27.2: 3/3 delivered for both, settle 279–361 ms for the sheet and 304–459 ms for the push; `--only tap` 44/44. With the settle wait disabled, the sheet check failed 0/3 while the push still passed 3/3: a tap during a push is not dropped, or the tree shows Done only once it ends, so the push check does not guard the wait. The sheet slides its uniform background under the point, the case feared to look still, and the wait still caught it. Left: I28.

### - [x] I21. Move `launch` out of `DeviceSession`, and keep private shapes in Native (S)

**Result (2026-11-25):**
- **Launch:** `AppLauncher` (`S:SimDriveCore/Apps/AppLauncher.swift`) runs `launch` and `openurl`, with `pid(fromLaunchOutput:)` as a pure, tested function. Not in `DeviceApps`, as planned: a launch needs settings, logs, screens and accessibility, and `DeviceApps` stays a thin `simctl` wrapper.
- **Error mapping:** `DeviceAccessibility` maps the translator's error for an app launched with app accessibility off to `app-accessibility-off` itself, given a closure that reads the setting, so `DeviceSession` lost `readAccessibility` and its six wrapped calls. Hit tests get the mapping too, which they lacked.
- **Native shapes:** `KeyboardBindings()` hides its runtime parameter; `SimulatorDevice.InterfaceOption` names its `choices` in CoreSimulator's order and reads and writes a choice by name, so Core knows no index order (`interfaceChoicesFollowCoreSimulatorsOrder` pins it); `GuestOrientationReading.physical` is a `PhysicalOrientation`, whose JSON keeps the old spelling (`PhysicalOrientationTests`).
- **Not done, on purpose:** deleting `hasTouchscreen` for a nil `GuestTouchscreen.open`. It also picks Apple TV's landscape panel and skips its screen-start wait, so the driver would only repeat the runtime-name check.
- **Checks:** `swift test` 171 and 30; on a new iPhone 17, iOS 27.2, `basics,tree,settings,logs,orientation` 89/89.

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

### - [x] I18. One way to wait with a deadline (M)

**Result (2026-11-25):**
- **The helper:** `withDeadline` and `poll(every:within:)` in `S:SimDriveCore/Support/Deadline.swift`. A deadline races the work against a timer, cancels the loser and returns at once, even when the work ignores cancellation, as a guest XPC call does; no timer outlives it, and cancelling the caller cancels the work. `poll` bounds the check in progress too, except with `finishingChecks`, which element waits pass: `tap --label --timeout 2000` must still finish a first read after boot that takes 13–15 s. `DeadlineTests` (9) use real 200 ms limits with wide margins rather than an injected clock, and fail when the cancellation is removed.
- **Moved onto it:** the screen-start wait, `element(within:)`, `waitUntilGone`, `becomesFrontmost` (now bounded at 30 s, reads included), the hinge's angle and settle waits, and the daemon client's start and exit waits. `Screens.settle` keeps its own loop, since it taps anyway when the limit passes.
- **Logs:** `attachedStream` is the one attach wait; `entry` (for `split`) now starts its action only once the stream has attached, instead of missing entries logged before it did.
- **Tools:** `DeveloperTools.run` collects both pipes with `readabilityHandler` and the exit with `terminationHandler`, so a running tool blocks no thread: 80 one-second tools at once finish in 1.07 s, against a timeout after 21 s before (`manyRunningToolsBlockNoThreads`).
- **Kept, on purpose:** the screenshot's orientation read that goes on after 1 s, for the next command (F14), and `prepare()`'s warm-up read. `docs/architecture.md` now names both as the only work that outlives a request.
- **Checks:** `swift test` 181 and 30. On new simulators, iOS 27.2: iPhone 17 `basics,tree,tap,logs,settings` 97/100, then `tap,logs` 53/54 on the same simulator; the failures were a first-boot `tap` timeout (F31) and the crash check (F32). Duo `posture` 11/14 on a new simulator (`posture-timeout`, F31), then 14/14 on it and 14/14 on a second new one. Later, with I12, `split left --from full` took 3.2 s and `split full` 1.6 s on a new Duo, against F17's 1.23 s: its log stream now attaches before the drag.

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

### - [x] I8. List elements an alert covers, and read apps other than the frontmost (M)

**Result (2026-11-25), on a new iPhone 17, iOS 27.2:**
- **The premise was wrong:** the testing snapshot simdrive reads already lists everything behind an app's own alert, then the alert's elements, and the client type changes nothing (tried 2, as NeoSimulator sets it, by hand), so simdrive sets none. What was missing was telling covered elements apart.
- **Hit tests cannot:** with the probe's alert up, a hit test at Play's point still answers with Play, though a tap there reaches nothing; only the element under the alert's box came out covered.
- **The layers can:** the window holds one `UITransitionView` per presentation, the newest last. `AccessibilityLayout` marks each element in an older layer `isBehindPresentation` (light reads now ask for `className`), tested with trees shaped like the probe's.
- **`tree --covered`** marks `covered: true` on elements behind a presentation, all of an app not in front, and others a hit test finds something else on, such as the keyboard; 0.18–0.23 s for 22 elements. It takes the light tree only.
- **`tree --app <bundle-id>`** reads the pid from `simctl spawn launchctl list` (`DeviceApps.runningProcess`, tested) through `translationApplicationObjectForPid:`, and fails with the new `app-not-running`. Behind the photo-permission alert, where SpringBoard is in front, it read the probe with all 18 onscreen elements covered. An app sent home is suspended within seconds and stops answering, so its timeout now says so.
- **`tap --label` too:** an element behind a presentation now fails with `element-covered` instead of a tap the guest drops.
- **Checks:** the matrix's `tap` section gains `covered_checks` (`-probeAlert`, `-probePhotos`); `tree,tap,keys` 64/64. `swift test` 186 and 30. Not checked: iPad popovers and form sheets, a Duo, and older runtimes.

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

### - [x] I30. Read guest preferences from the host's plist files (S)

**Result (2026-11-25):** `GuestPreferences.export` reads `<dataPath>/Library/Preferences/<domain>.plist` on the Mac, treats a missing file as an empty domain, as `defaults export` does, and falls back to `simctl spawn defaults export` only without a data path or a file that does not parse. Writes stay with `defaults write`. Staleness checked first on an iPhone 17, iOS 27.2: after `setting reduce-motion on`, `off` and `on`, the file held each new value at once, 0.2 s and 1 s later, since `defaults write` has flushed when it returns. Reading every setting went from about 0.6 s to 0.02 s warm, and the cold `settings` section on a new simulator passed 47/47, its restore check included. Not checked: a change made in the guest's own Settings app, which cfprefsd may write to the file a moment later.

- **Why:** found in the source comparison (2026-11-25). Every `setting` read runs `simctl spawn defaults export` in the guest, and right after a boot that outlasted 60 s (F27, F31). The guest's preferences are files on the Mac, `<dataDirectory>/Library/Preferences/<domain>.plist`; fastlane edits them in place (`fastlane_core/lib/fastlane_core/device_manager.rb:235-246@d7df171`), and idb runs guest tools in process through `SimDevice spawnAsyncWithPath:` rather than `simctl` (`I:Management/SimulatorSubprocessLauncher.swift:28-56`, about 0.1 s less per call).
- **Do:** read in `GuestPreferences.export` from the plist; keep writes through `defaults write`, which goes through cfprefsd. First check staleness: does the file show a write made a moment before, or does cfprefsd hold it? If it lags, read the file only for the snapshot of all settings and the matrix's restore.
- **Test:** `setting` timings on a new simulator right after `bootstatus`; the matrix's `settings` section.

### - [x] I12. Read the Duo's Home screen from the active panel only (M)

**Result (2026-11-25), on new iPhone Duos, iOS 27.2:**
- **Steps 1 and 2** are in `PanelWindows` (pure, `PanelWindowsTests`), which `DeviceAccessibility` applies to every read on a device with more than one display. It drops top-level windows at the origin sized like another panel, in points or pixels and either orientation, or like this panel's pixels, and turns windows of this panel's native size into interface coordinates through `ScreenMapping.screenshotPoint(fromDigitizer:)`, the inverse of the tap mapping. Closed, the Home screen went from 26 elements with duplicates at x up to 4.9 to 15; open, to 7, the dock, search, clock and page dots.
- **Step 3:** the snapshot accepts attribute 2123 and returns every node's display in simdrive's one request, so no per-button request is needed. Light reads ask for it only on devices with several displays (`Screens.hasSeveralDisplays`): on an iPhone 17, three of four ordered rounds of `tree` were slower with it, within noise. `PanelWindows` then drops elements whose display is set and is not the screen's. Closed, Photos, Maps, Health and an unlabelled node reported display 3 and went; open, `tree` lists Photos, Maps and Health, the dock and the clock, all at their drawn places.
- **Checks:** the matrix's `tree,tap,posture` 65/65 on a Duo, `fresh.py --only tree,posture` 35/35 on a new Duo, `fresh.py --only tree,tap` on an iPhone 17 (tree median 88 ms).
- **Left in F35:** hit tests on the open Home screen find nothing; icons SpringBoard gives only the other panel's views are missing from the tree; closed, the inner panel's Search stays off the cover.

**Before step 3 (2026-11-25):**
**Left, measured today:**
- **Open, the inner panel's icons are not in the tree.** Its `SBRootFolderView` lists only the Today view's clip views and the page control; the icons shown in the screenshot are in no window, and hit tests at Photos, Calendar and even the dock's Safari return `no-element`. Before this change, `tree` listed the cover panel's icon layout there instead, at wrong points. Next: check whether a hit test that passes the inner display's ID finds them, whether scrolling the Home screen or a reboot loads them, and what AXe's tree shows in the same state.
- **Closed, step 3:** Photos reads (0.60, 0.54), a frame 0.186 wide where the other icons are 0.137, though it is drawn at (0.31, 0.42): the inner panel's frame. AXe drops such buttons after asking each for its display.
- **Found upstream (2026-11-25, source comparison):**
  - **The display request:** AXe builds `AXPTranslatorRequest requestWithTranslation:` from the element, with `requestType` 2 (one attribute), `attributeType` 63 and `parameters` `["parameter": 2123]`, and sends it with `translator.sendRequest`; an inner-panel icon answered 3, the outer copy 1 (`A:FBAXPlatformElement.swift:150-166@581c5b7`). It asks only when the read's root holds another panel's window (`A:FBAXInactivePanelWindowFilter.swift:124-155`), and keeps an element whose display is missing or 0. **Try first:** add 2123 to `SnapshotAttribute`, which may return every node's display in simdrive's one snapshot request; fall back to AXe's per-button request if the snapshot refuses it (some attribute numbers crash or return subtrees, `docs/design-decisions.md`).
  - **Nobody reads the open panel's icons:** AXe's 9dfd60d says SpringBoard hands one panel's icon list the other panel's views, and the icons drawn there are in no tree, "can only be tapped by coordinates". So the missing icons are SpringBoard's, not simdrive's; document it and stop there.
  - **`frontmostApplicationWithDisplayId:` ignores its display** (idb decoded request type 4's guest handler, `I:FBSimulatorBridgeProtocol/BridgeAXTranslatorAttribute.swift:197`), matching simdrive's measurement. **Hit tests do use it:** AXe passes the panel's `screenID`, checked against CoreDevice's `getdisplayinfo`, and a point in the panel's native, unturned points (`A:FBSimulatorAccessibilityCommands.swift:97-108`, `A:FBAXTranslationRequest.swift:331-337`). Check what `DeviceAccessibility.element(at:)` passes on the open Duo: today's empty hit tests may be a wrong display or unturned point, not only the missing icons.
  - **Settle after a hinge change:** idb waits for the display layout to settle before input, accessibility or screenshots (`I:FBSimulatorControl/README.md:208-223`); AXe re-measures the active panel on every attempt (`A:Sources/AXe/Utilities/AccessibilityFetcher.swift:76-92`).


- **Problem:** on a Duo's Home screen, `tree` mixes both panels. Open, on iOS 27.2 (`688B6C57`), it returned 26 VoiceOver elements, 13 of them duplicates (Safari, Messages, Options, the clock), with points from -0.43 to 2.42. Closed was alike. Apps are not affected: the probe's tree is right either way.
- **Measured:** the display ID passed to `frontmostApplicationWithDisplayId:` changes nothing: 0, 1 and 3 return the same tree, open and closed, so the planned fix does not work. SpringBoard's top-level windows (open, interface 951×669 points) come in four sizes, each at the origin: the inner panel in native portrait points (669×951) and pixels (2007×2853), and the outer panel in points (466×678) and pixels (1398×2034). AXe handles three problems, all needed (`A:Packages/IDBKit/FBSimulatorControl/Commands/FBAXInactivePanelWindowFilter.swift`, `FBAXTranslationRequest.swift:357-380`):
  1. **Other panel's windows.** Dropping top-level windows at the origin with the other panel's size, in points or pixels and either orientation, removed every labelled duplicate. The panels' sizes are in the device type's `capabilities.plist` (`displays`, `integrated`, `hasDigitizer`), or in `Screens`.
  2. **Native frames.** On a quarter-turned panel, SpringBoard's windows of the panel's native size keep native coordinates. Safari's raw point (0.3656, 0.0715) matches its dock icon at (0.95, 0.52) only after AXe's conversion: x = native height − y, y = x.
  3. **Icons with the other panel's frames.** Kept windows still list some icons at the outer panel's places: Calendar reads (0.06, 0.42), drawn at (0.525, 0.43). AXe asks each button for its display (one request per button, only when step 1 dropped a window) and drops those on another.
- **Do:** the three steps in `DeviceAccessibility`, with the windows' classification in `AccessibilityLayout`, which knows the panel; the per-button display request in `SimulatorAccessibility`. **Test:** `tree` on the Home screen of a closed and an open Duo, every point against the screenshot; the probe's tree unchanged; the matrix's posture section; time `tree` on the Home screen.

### - [x] I6. Detect a sleeping display, and wake it (M)

**Result (2026-11-25):** step 3 is `DisplayWake`, run before `tap`, `swipe`, `pinch`, `rotate`, `alert accept|dismiss` and setting `orientation`: when the target screen's backlight reads `dimmed` or `off`, it presses Lock until it reads `on` (at most three presses, about 1 s each), and unlocks with the bottom-edge swipe, then Home where the edge is ignored (iOS 17.0, F16), only a device that was unlocked before; one that was locked stays on its lock screen, so an agent testing the lock screen keeps it. Results carry `"woke": true`; failing to light or unlock is the new `display-asleep`. On a new iPhone 17, iOS 27.2, after `button lock` (dimmed, locked) a `tap` returned `woke` in 1.2 s with the backlight `on` and the device still locked; a tap on a lit display took 88 ms with the backlight read added. Not verified: the unlocked idle-dim path end to end, since two 8-minute idles after launching the probe, one after the `buttons` section, never dimmed; the sequence it runs is the one measured by hand in `docs/device-behavior.md`. Step 4, an opt-out flag, moved to N34.

**Step 3 attempt (2026-11-25):** not built, since idle sleep did not reproduce. On a new iPhone 17, iOS 27.2, `doctor` read `backlight` `on` and unlocked throughout: 130 s idle after launching the probe, 180 s after one tap in it, 90 s on the Home screen, and once 75 s after a tap with no reads in between. So what dims the display is unknown: the single `dimmed` read below may have come from something else in that run. **Next:** find a reliable trigger first (a simulator left idle much longer, one shown in Simulator.app or DeviceHub, older runtimes, or an Auto-Lock preference such as `SBAutoLockTime` in `com.apple.springboard`), then wake before input as step 3 says, checked against it.
**Lead (2026-11-25, while doing N8):** after `Evaluation/fresh.py --only tree,keys,buttons` on a new iPhone 17, iOS 27.2, `doctor` read `dimmed` and unlocked a minute or so later, and screenshots stayed on the dimmed frame through `launch`, a tap and `button keyboard`, while `tree` answered. The buttons section ends with `lock`, `lock`, an edge swipe, `siri` and `home`, so one of those presses likely starts the idle timer that a fresh boot does not: try them one at a time, then idle.
**Reproduced (2026-11-25, whole-matrix run at 0d2c5fa):** a new iPhone 17, iOS 27.2, left idle about 5 minutes after `Evaluation/fresh.py` finished its whole matrix (its last sections `services`, then `shake` and `memory-warning`), read `backlight` `dimmed`; `status-bar override` then drew nothing new, since screenshots froze on the dimmed frame, until `lock`, `lock` and the edge swipe woke it. So a long idle after a full run is a trigger to test step 3 against.
**Found upstream (2026-11-25, source comparison):** agent-device reads the Darwin state `com.apple.springboard.hasBlankedScreen` beside `lockstate`, wakes with Lock, polls every 50 ms for up to 5 s until the screen is no longer blanked, and edge-swipes only if still locked; a swipe on a blanked screen unlocks SpringBoard but leaves the screen off (`D:RunnerTests+LockScreen.swift:36-40,195-256@24f8181`). AXe reads `backlightState` (`activeOn`, `activeDimmed`, …) from CoreDevice's `com.apple.coredevice.action.displayinfo` and rechecks before each event (`A:FBSimulatorDisplayInfoReader.swift:46-52`). `SimDevice setDisplayBacklightActive:error:` exists (`I:PrivateHeaders/CoreSimulator/SimDevice.h:315`), unused upstream: a candidate wake without a Lock press. So: add `hasBlankedScreen` to `doctor`, and try the backlight call as step 3's wake. No tool prevents sleep; XCTest's user-presence assertion needs a testmanagerd session (I16's cost).

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

### - [x] I35. Faster screenshots on physical devices (S)

- **Result (2026-11-27):** `GuestScreenCapture` reads `CaptureScreenshotOutput.image` from the native output, skipping JSON, which saves a 20 MB string per 4K capture but no time. Five warm 4K Apple TV captures over Wi-Fi took 6.3–9.1 s with JSON and 6.2–8.0 s without, and `devicectl` takes as long. The device's PNG encoding and the network bound it, and `ScreenshotImageFormat` offers only `png`. Binding the getter as `CGImage` crashed ABIBridge, so it is bound as `AnyObject`. Left: I36.
- **Why:** left from N35. A 3840 × 2160 Apple TV screenshot took 8.2 s over Wi-Fi, and an iPhone's 1.3–2.3 s over USB. `GuestScreenCapture` decodes `CaptureScreenshotOutput` to JSON, so the image is PNG-encoded on the device, base64-encoded, JSON-parsed, decoded, then encoded again as PNG.
- **Do:** read `CaptureScreenshotOutput.image` as a `CGImage` through ABIBridge instead of through JSON. Measure several rounds before and after. Check whether the input takes a smaller size for calibration, which needs only the image's size; the display info's `nativeSize` may give that with no capture.

## 3. New features

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

### - [x] N3. `shake` (S)

**Result (2026-11-25):** `shake` posts `com.apple.UIKit.SimulatorShake` and returns `{}`. The probe logs `SHAKE` from its view controller's `motionEnded`, and the matrix's `services` section checks it: 11/11 on a new iPhone 17, iOS 27.2. Not checked: iPad, older runtimes, and tvOS, where UIKit has no shake.

- **Do:** `SimDevice postDarwinNotification` of `com.apple.UIKit.SimulatorShake` (`N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:856`). simdrive already posts notifications (`S:SimDriveNative/Simulator/SimulatorDevice.swift:96`). Put the name in a `SimDriveCore` constant, used by a `DeviceSession` method.
- **Test:** the probe logs `SHAKE` from `motionEnded(_:with:)` on its view controller; add a matrix check.

### - [x] N4. `memory-warning` (S)

**Result (2026-11-25):** `memory-warning` writes an empty file at the `SimDevice`'s `memoryWarningFilePath` (`SimulatorDevice.memoryWarningFile()`), which the guest watches, and returns `{}`; a device that reports no path fails with the new `memory-warning-unsupported`. The probe logs `MEMORY` from `applicationDidReceiveMemoryWarning`, and the matrix's `services` section checks it: 12/12 on a new iPhone 17, iOS 27.2. Not checked: older runtimes and tvOS.

- **Do:** write an empty file at `SimDevice.memoryWarningFilePath`, as `SimDevice.simulateMemoryWarning` does (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:164-165,1038-1044`; `N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:1301`). Add `memoryWarningFilePath` to `SimulatorDevice`.
- **Test:** the probe logs `MEMORY` from `UIApplication.didReceiveMemoryWarningNotification`; add a matrix check.

### - [x] N6. `slow-animations on|off` (S)

**Result (2026-11-25):** a `setting` row, `slow-animations`, rather than a command. It is the catalog's fourth storage kind, `notificationState`: setting it sets `com.apple.UIKit.SimulatorSlowMotionAnimationState`'s Darwin state to 1 or 0 and posts it (`SimulatorDevice.setDarwinNotificationState`), and reading it reads the state back; it is available where `SimDevice supportsFeature:` accepts `com.apple.UIKit.SimulatorSlowMotionStateful` (`SimulatorDevice.supportsFeature`). The probe logs UIKit's `UIAnimationDragCoefficient()`, looked up with `dlsym`, as `drag=` on its STATUS line: 1, then 10 while on. The matrix's `settings` section checks it: iPhone 17 iOS 27.2 47/47 (after F31's first-boot timeout) and iPhone 15 iOS 17.0 42/42, both new, so no minimum OS.

- **Do:** set the state of `com.apple.UIKit.SimulatorSlowMotionAnimationState` and post it (`N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:1142-1157`). Check that the runtime supports it first (`com.apple.UIKit.SimulatorSlowMotionStateful`, `:82-84`). This could be a `setting` row (`slow-animations`, toggle) instead of a command.
- **Test:** the probe logs `UIView.inheritedAnimationDuration`, or the layer's speed, of an animation it runs. Simplest: time a known 0.3 s animation with two screenshots.

### - [x] N8. More buttons (S)

**Result (2026-11-25):** `HardwareButton` gives each button its usage page and adds `keyboard` (0x0C/0xB8), `screenshot` (0x0C/0x65) and `action` (0x0B/0x2D), which the parser holds 500 ms by default. On a new iPhone 17, iOS 27.2: `keyboard` hides and shows the software keyboard, `screenshot` opens the guest's screenshot editor, `action` toggles silent mode, and `home --repeat 2` opens the app switcher, since `--repeat` already waits 150 ms between presses, so no `app-switcher` button was added. The matrix's `keys` section checks `keyboard` by hit-testing the keyboard area, because the tree lists a hidden keyboard's keys too: 39/39. Left out: `side` (0x0C/0x95) changed nothing visible, and `apple-pay` (0x1BA) has nothing to show without Wallet; add them once an effect can be checked. `screenshot` and `action` have no matrix check, only those screenshots.

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

### - [x] N11. `push`, `privacy` and `status-bar` wrappers (S)

**Result (2026-11-25):** the three commands wrap `simctl` and add no error codes: `simctl` checks services, payloads and values, and its failures come back as `simctl`. The parser checks shapes first: `privacy`'s action and that grant and revoke name an app, and each `status-bar` option's values and ranges (`StatusBarOverride`). `push -` reads standard input in the client, which inlines it as `--json`, as `run -` does. `simctl status_bar` still works on Xcode 27, so devicectl was not needed. The matrix's new `services` section passes 10/10 on a new iPhone 17, iOS 27.2: a push from standard input reaches the probe's notification center delegate; `privacy grant` and `reset` of photos show as authorization 3 and 0 on relaunch; an unknown service fails with `simctl`; equal status bar overrides draw byte-equal screenshots and a different time a different one. Learned (in `docs/device-behavior.md`): the first push after a boot takes ~52 s, hence a 120 s limit; `simctl push` reports "Source is not authorized" for an app without notification permission, though an app in front still receives it, so the matrix accepts that; overrides do not change what accessibility reads. Not done: `status-bar list`, and a `push-not-authorized` code instead of `simctl` for that failure, a contract choice left for the user.

NeoSimulator has none of these; `simctl` covers them.

- **Commands:**
  - `push <bundle-id> <payload.json|->` runs `simctl push`.
  - `privacy <grant|revoke|reset> <service> <bundle-id>` runs `simctl privacy`.
  - `status-bar override [--time 9:41] [--battery 100] …` and `status-bar clear` run `simctl status_bar`.
- **Why:** agents need permissions granted without tapping alerts, deterministic status bars for screenshots, and push handling.
- **Seen (2026-11-24, upstream review):** on Xcode 27, AXe overrides the status bar with `xcrun devicectl device simulate statusBar override` rather than `simctl status_bar`.
- **Test:** the probe logs `PUSH <aps.alert>` from `userNotificationCenter(_:willPresent:)`. A privacy grant makes the probe's location request skip its alert. A status-bar override shows in a screenshot.

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

### - [x] N32. `swipe --until-label|--until-id --max-swipes n`: scroll an element into view (S, needs N27)

**Result:** `swipe … --until-label|--until-id [--max-swipes N]` reads the light tree first, then swipes, waits 400 ms for the scroll to settle and reads again. It stops at the first read where one onscreen element matches, returning `{"element", "swipes"}`, or fails with `no-element` after `--max-swipes` (10 by default). It takes no `--edge` or `--display`. The matrix's `tap` section scrolls the probe to its last row (2 swipes) and back to Play (1), and passes 40/40 on iPhone 17, iOS 27.2.

- **Why:** split from N27. `tap --label` fails with `element-offscreen` for a row scrolled out of view, and the agent must then swipe and reread the tree by hand.
- **Read:** N27's sources (AXe's `gesture scroll-* --until-id`, agent-device's `scroll --until`); `S:SimDriveCore/Accessibility/ElementSelector.swift` (`isShown`), `S:SimDriveCore/Accessibility/DeviceAccessibility.swift` (`element(_:within:)`).
- **Do:** repeat the swipe, then read the light tree, until the selector is shown or `--max-swipes` runs out; fail with `no-element` naming how many swipes ran. Return the element, as `wait --label` does.
- **Test:** parser tests; the matrix's `tap` section scrolls the probe's list until its last row is on screen.

### - [x] N29. `alert`: read, accept and dismiss system alerts (M, needs I8)

**Result (2026-11-25), on an iPhone 17, iOS 27.2:**
- **What an alert looks like:** an app's own alert and SpringBoard's system ones are the same `_UIAlertControllerPhoneTVMacView` (view controller `UIAlertController` or `_SBAlertController`), labelled with the title, holding the title and message labels and then the buttons. Permission buttons carry identifiers ending `-allow-button`, `-deny-button` and `-limited-button`. Recorded in `docs/device-behavior.md`.
- **`alert [accept|dismiss] [--timeout ms]`:** `AlertReader` (pure, `AlertReaderTests`) finds the newest alert in the frontmost tree, the light read now carrying class names (I8). Answering picks by permission identifier, then English labels, then UIKit's order (default action last, cancel first), and taps the button's placed point with the settle wait, as `tap --label` does, so a same-labelled element behind the alert cannot be hit. It waits 5000 ms for an alert by default and fails with the new `no-alert`; reading looks once unless given `--timeout`.
- **Checks:** the matrix's `covered_checks` reads and dismisses the probe's alert, denies the photo permission (`PHOTOS status=2`) and grants it (`status=3`), and checks `no-alert`; `tree,tap` 56/56. Left: N33.

- **Read:** agent-device's `alert get|wait|accept|dismiss` ranks localized button labels (`D:website/docs/docs/commands.md:473-484`). idb detects modals from `SBAlertItemWindow` and `_UIAlertController*` windows (`I:SimulatorFrameworkBridge/Swift/AccessibilityService.swift:162-165,785-820`).
- **Do:** after I8 reads SpringBoard, find an alert's buttons in its tree and tap them by label; `alert` returns the title, message and buttons, or null.
- **Test:** the probe requests a permission at launch; accept and deny it in the matrix.

### - [x] N35. Physical devices on iOS and tvOS 27 (L)

- **Result (2026-11-27):** physical iPhones, iPads and Apple TVs on iOS and tvOS 27 take input, screenshots, orientation, the pasteboard, setting actions and app commands through shared drivers; the rest fails with named `-unsupported` codes. Device mode in the matrix passed 48/48 on an iPhone 15 Pro (iOS 27.2.1, USB) and 20/20 on an Apple TV 4K (tvOS 27.2.1, Wi-Fi), with each device left as found. The simulator matrix passed 157/157 on an iPhone 17, iOS 27.2. Left: N36, N37, N38, I35, F42.
- **Steps 1–5 and step 7:**
  - **Decisions taken with the user:**
    - Error codes per capability: `logs-unsupported`, `push-unsupported`, `privacy-unsupported`, `shake-unsupported` and `status-bar-unsupported`, besides the existing `accessibility-unsupported`.
    - Orientation is restored on `stop` and daemon exit.
    - A device is named by CoreDevice's identifier or its hardware UDID; `booted` still means simulators only.
  - **Code:**
    - `GuestLink` with `SimulatorLink` and `RemoteDeviceLink`, and `Guest(simulator:)` and `Guest(physical:)`.
    - `GuestActions` is shared by the setting actions and `GuestScreenCapture`.
    - `PhysicalDevices` lists devices and `Devices` resolves them.
    - `ScreenSource`, with `SimulatorScreens` and `DeviceScreens`.
    - `AppControl`, with `SimulatorApps` and `DeviceAppControl` over `devicectl`.
    - Settings rows have ordered storages, and five rows gained action storages.
    - `DeviceSession` keeps simulator-only parts apart.
  - **Verified with the release build:**
    - On the Apple TV (tvOS 27.2.1, Wi-Fi): `list`, `doctor`, `screenshot` (4K in 8.2 s), `button left|right` as screenshots showed, `setting`, and the expected `accessibility-unsupported`, `logs-unsupported`, `orientation-unsupported` and `pasteboard-unsupported`.
    - On the iPhone 15 Pro (iOS 27.2.1, USB): `screenshot` (1.3–2.3 s), `swipe` both ways, `launch` (1.1 s), `swipe --edge bottom` going home, `setting`, and `orientation` set, with `stop` restoring `faceUp`. The device was named by its hardware UDID too.
    - Unit tests: `PhysicalDeviceTests`, proved able to fail.
  - **Matrix device mode (step 7):**
    - The probe is built by `xcodebuild` from `Evaluation/Probe/AXProbe.xcodeproj` and signed with the owner's team (`SIMDRIVE_TEAM`). Automatic provisioning first failed until the team accepted Apple's latest Program License Agreement.
    - The probe logs `LAYOUT` for taps without a tree, and its log is copied with `devicectl`.
    - Settings checks start from each setting's current value, since the owner had Increase Contrast on.
    - `uninstall` of a missing app on a device now returns `app-not-installed`.
- **Spike (2026-11-27):** step 0 passed on a tvOS device: an Apple TV 4K on tvOS 27.2.1, over the local network.
  - simdrive's own guest messages, sent over `RemoteDevice.remoteXPCConnection`, created a button service and pressed `menu`, `left` and `right`, as screenshots confirmed. The barrier answers there too.
  - This confirms the channel seam of the design below, so the drivers can stay unchanged.
  - Details are in [private APIs](../docs/private-apis.md#physical-devices).
  - A second spike added the design's `GuestLink` under `GuestConnection`. The unchanged `GuestButtons`, `GuestKeyboard` and `GuestSettingActions` drove the Apple TV: buttons, typing into Search, and appearance reads.
  - A screenshot taken in process through `CaptureScreenshotActionDeclaration` needs a lit display. While the Apple TV sleeps it fails with 25005, so `DisplayWake` must cover devices too. Waking lands on tvOS's profile picker.
  - Setting actions on a device need the CoreDevice identifier as `deviceIdentifier`.
  - **iPhone, iOS 27.2.1, wired.** The unchanged `GuestTouchscreen` and `GuestOrientation` worked on an iPhone 15 Pro. Taps and swipes landed, and the bottom-edge swipe went home. Rotation also worked: Safari turned to landscape, and screenshots follow the interface. So did the seven appearance reads and in-process screenshots (1.1 s). A system alert blocked the home swipe.
  - **Orientation needs design.** On a device, `orientation` sets a simulated physical orientation that persists. CoreDevice has no call to clear it, only `faceUp` and `faceDown` among the values it accepts. The device design must record the reading before setting it and restore it, or the command must say that it holds the orientation.
  - **Still unverified:** the pasteboard (not read on a personal phone), pinch and rotate, buttons and the keyboard on an iPhone, and the simulator matrix on the link layer.
  - The spike code was throwaway executable targets, not kept.
- **Why:** agents test on real hardware too. This was investigated without a device first; only the spike above has run against one.
- **Found on this Mac (Xcode 27.2, CoreDevice 651.32):**
  - The iOS and tvOS 27 developer disk images (`/Library/Developer/DeveloperDiskImages/{iOS,tvOS}_DDI`, mounted read-only) ship CoreDevice daemons with the features simdrive already sends in simulators. `dtuhidd` has `remote.universalhidservice`, `remote.hid.digitizer`, `remote.hid.button`, `remote.hid.keyboard` and `remote.hid.vendordefined`. `dthidd` has `remote.devicecontrol.orientation`. `dtpasteboardd` has `pasteboard`. `dtconfigurationd` has `customizeuistyle`, `customizeappearancesettings`, `customizeliquidglass` and `voiceover`. `dtscreencaptured` has `capturescreenshot`. `dtdeviceinfod` has `getdisplayinfo`, `getlockstate` and `monitormotion`. `dtlocationd` has `simulatelocation`. `dtappserviced` covers launch, install, signals, memory warnings and stdio.
  - Each daemon requires a `com.apple.private.CoreDevice.*` entitlement of its RemoteXPC peer. The Mac-side holder is `CoreDevice.framework/XPCServices/CoreDeviceService.xpc`, which runs for any process loading the framework. That is how an unentitled `devicectl` and NeoSimulator reach these services, and why simdrive could too.
  - `devicectl device` in Xcode 27.2 has these subcommands: `capture screenshot|screen-record`, `orientation get|set|rotate`, `pasteboard`, `settings appearance` (style, text size, contrast, reduce motion and transparency, borders, Liquid Glass, color filter), `settings voiceover`, `simulate location|statusBar|biometrics`, `info displays|lockState`, and `process launch|openURL|sendMemoryWarning`.
  - The device's testmanagerd `remote.automation` service requires `AppleInternal`.
  - **The tvOS 27 image differs from the iOS one:**
    - `dtuhidd` adds `remote.hid.tvremote`, a dedicated Siri Remote feature beside `remote.hid.button`.
    - `dthidd` lists no features, so it has no orientation.
    - There is no `dtpasteboardd`.
    - `dtconfigurationd` lacks `customizeliquidglass`.
    - Screenshots, appearance, VoiceOver, display info, location and the app service match iOS.
    - An Apple TV pairs over the network only (`remote pair` with a PIN), so every call crosses Wi-Fi or Ethernet.
- **Read:**
  - **Physical-device prior art:** NeoSimulator reaches physical devices through `RemoteDevice.getImplementation(for:)` with `UniversalHIDServiceCapability`, `ButtonHIDCapability` and `DigitizerHIDCapability` (`N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceHIDService.swift:45-93`, `N:NeoSimulatorPresentationAdapters/Native/CoreDeviceScreenInput.swift:25-92` @c9710cf), streams screens over USB and Wi-Fi (#544), and follows rotation (#555).
  - **Raw-protocol versions:**
    - pymobiledevice3 `remote/core_device/{hid_service,screen_capture_service,orientation_service}.py` and `remote/ddi_services.py`. It dates these services to DDI build 27A5194q.
    - go-ios `ios/hid/{digitizer,button}.go` and `ios/screencapture`. On iOS 18, go-ios gets CoreDeviceError 9021.
    - idb `FBDeviceHID`.
  - **Clones:** `/tmp/devsurvey/`.
- **What each command would need:**

  | Command | Physical transport | iOS / tvOS |
  | --- | --- | --- |
  | `tap`, `swipe` (with `--edge`), `pinch`, `rotate`, `key`, `type`, `button` | CoreDevice HID capabilities, as in simulators but through `RemoteDevice`. pymobiledevice3 says raw UniversalHID reports are dropped without an active media stream, while the digitizer and button features are not; check which holds through CoreDevice. No acknowledgment, so the matrix must check effects. | 27+ |
  | `screenshot` | `capturescreenshot`, per display | 27+; DVT screenshot service for 17–26, main display only |
  | `orientation` | `remote.devicecontrol.orientation` (rotates even when locked, per pymobiledevice3) | 27+ |
  | `pasteboard` | `PasteboardCapability`, unchanged | 27+ (go-ios says 17+, unconfirmed) |
  | `setting` | The configuration actions simdrive already sends, through CoreDevice rather than a guest Mach lookup. The preference-file reads (I30) do not exist on a device, so reads go through the actions or the AX audit daemon's settings. | 27+ |
  | `launch`, `install`, `uninstall`, `openurl`, `memory-warning` | CoreDevice appservice (`devicectl process …`), with stdout and stderr over its stdio socket | 17+ |
  | `logs` | `os_trace_relay` for the unified log; crash reports over `crashreportcopymobile` (AFC). Neither is wrapped by CoreDevice. Needs a new driver. | 17+ |
  | `status-bar`, location | `devicectl device simulate statusBar` and `simulatelocation` (location is a new command) | 27+ |
  | `doctor` | `getdisplayinfo`, `getlockstate` | 27+ |
  | `tree`, `tree <x> <y>`, `tap --label`, `wait --label`, `alert`, `swipe --until-*`, `tree --covered` | **None without an XCTest runner.** `AXPTranslator` reaches a guest only through CoreSimulator. The AX audit daemon (`com.apple.accessibility.axAuditDaemon.remoteserver`, which Accessibility Inspector uses) gives VoiceOver-order focus with label, value and identifier, but no frames, and its point hit test answers empty on devices (go-ios on iOS 18.4). A full tree needs a signed runner app, as WebDriverAgent or agent-device use, at 0.7–3.7 s a touch through the runner. | — |
  | `posture`, `split` | No hinge on a real device to drive | — |
  | `push`, `privacy`, `shake` | None found: `simctl`-only, and no host-side privacy grant exists for devices | — |

- **Decide with the user:**
  - Whether simdrive takes on devices at all. Its scope so far is simulators ("Not planned" below).
  - The device floor. 27+ keeps one transport. Supporting 17–26 needs DVT and lockdown drivers and still has no input.
  - Whether to ship without element commands, or to add a runner, which brings signing, a team ID and an install step.
  - Device identity and selection: `list`, `booted` and the UDID no longer come from CoreSimulator.
- **Design (2026-11-27): the transport splits at the channel, not at the drivers.**
  - **Drivers stay unchanged.** Every input and control driver (`GuestTouchscreen`, `GuestKeyboard`, `GuestButtons`, `GuestOrientation`, `GuestSettingActions`, the pasteboard) only calls `connection(to: feature)` on `S:SimDriveNative/Guest/SimulatorGuest.swift`, then posts, requests, flushes and creates services on a `GuestConnection`.
  - **CoreDevice has the physical equivalent:** `RemoteDevice.remoteXPCConnection(toFeatureIdentifiedBy:connectionMode:handlingEventsOn:) -> OS_xpc_remote_connection`, plus `RemoteDevice.enableDeveloperDiskImageServices(options:…)`, both in CoreDevice's symbols. The daemon on the far end is the same binary, so the messages should be the same (unverified).
  - **SimDriveNative:**
    - A `GuestLink` protocol: `SimulatorLink` is today's `xpc_connection_t`, and `RemoteDeviceLink` wraps `xpc_remote_connection`. `GuestConnection` keeps its failure tracking, deadlines and `flush`/`drain` on top. Drain timing moves to the link.
    - `SimulatorGuest` becomes `Guest`, with factories `Guest.simulator(SimulatorDevice)` and `Guest.device(CoreDeviceRemote)`.
    - `CoreDeviceRemote.open` takes an identity: a simulator's UDID or a physical device's identifier.
    - New physical drivers: `DeviceScreenCapture` (`capturescreenshot`), `DeviceDisplayInfo` (`getdisplayinfo`, `getlockstate`) and `DeviceAppService` (appservice).
  - **SimDriveCore:**
    - `DeviceIdentity` (`kind`, `id`, `name`, `platform`, `osVersion`, `hasTouchscreen`). `list` and `booted` merge booted simulators with paired devices from `CoreDeviceManager`. The daemon and state paths key on `id`.
    - `DeviceBackend`, built once by `.simulator(…)` or `.physical(…)`, holds `guest`, `ScreenSource`, `PowerState`, `AppControl`, `LogSource`, `AccessibilitySource` (nil on devices), `KeyboardLayoutSource` (US on devices) and `isCurrent`. `DeviceSession`, `Screens`, `DisplayWake`, `DeviceAccessibility`, `SplitView` and `AppLauncher` take parts instead of `SimulatorDevice`. A missing part fails with a named code.
    - `SettingCatalog` rows get an ordered list of storages. The backend says which storage kinds it has, and devices have only actions. Appearance, text size and the like gain `dtconfigurationd` action storages.
    - Parsing, JSON, geometry, gestures, element logic, log digests, `run` and the daemon protocol stay unchanged.
  - **Decide before step 2:**
    - The new codes: `accessibility-unsupported`, `logs-unsupported`, `push-unsupported` and `privacy-unsupported`, or one `unsupported-on-device` code instead.
    - `device-disconnected` (retryable), `developer-mode-off` and `device-locked`.
    - A `"kind"` field in `list`.
- **Do (if yes), each step one commit:**
  0. **A spike on a real iPhone and Apple TV, both on 27.** It gates the rest.
     - List `supportsFeature`.
     - Through `remoteXPCConnection`, send today's digitizer tap and the barrier, then keyboard and buttons through `universalhidservice`, with and without a media stream.
     - Read orientation, take a screenshot, and run one setting action.
     - Record the results in `docs/private-apis.md`.
     - If the raw messages differ, the device branch of step 3 uses CoreDevice's typed capabilities (`HIDDigitizer.send`, as NeoSimulator does) behind the same drivers.
  1. **A refactor of simulators only, with no behavior change:** `GuestLink` with `SimulatorLink`, `Guest.simulator`, `DeviceIdentity`, and `DeviceBackend` with its simulator parts. The full matrix must match v0.1.2 on new iPhone, Duo and Apple TV simulators.
  2. **Device discovery and selection**, with the contract changes above.
  3. **`RemoteDeviceLink` and `Guest.device`:** input, orientation, pasteboard and setting actions.
  4. **Screens, wake and `doctor`** from capture and display info, plus the settings storage list.
  5. **`AppControl` for devices.**
  6. **`LogSource` over `os_trace_relay`** and crash reports.
  7. **Matrix device mode**, skipping `tree`, `alert`, `posture`, `privacy`, `push`, and `pasteboard` on tvOS. The probe app is signed with a team ID from the environment.
- **Edge cases:**
  - Developer Mode is off, or the DDI is not mounted: mount it once per session.
  - A device locked with a passcode fails with `device-locked`; simdrive never types a passcode.
  - A Wi-Fi drop or an unplugged cable gives `device-disconnected`, and the lazy parts reopen.
  - An Apple TV is reached over the network only.
  - A foreground app using the camera or microphone refuses the media stream.
  - Whether idle release still matters on a device.
  - The barrier reply is the only acknowledgment.
- **Test:**
  - Unit tests: `DeviceIdentity` merging and resolution, backend part selection with fakes, the order of setting storages, and the error mapping.
  - The matrix's device mode on a real iPhone and Apple TV, both on 27. Say which device and OS ran.
