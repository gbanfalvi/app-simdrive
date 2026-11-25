# Backlog

Work found by reviewing [NeoSimulator](https://github.com/lynnswap/NeoSimulator) at `d467c60` (2026-11-17), 50 commits past the `1dfc4af` that simdrive's guest input was ported from, then [AXe](https://github.com/cameroncooke/AXe), [idb](https://github.com/meta/idb) and [agent-device](https://github.com/callstack/agent-device) (2026-11-18). Ordered by kind (fixes, then improvements to existing commands, then new features), and within each kind by cost. This file holds open work only; items that have landed are in [completed.md](completed.md), under the same sections and IDs.

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
- **When an item lands**, in the commit that lands it: tick it, add its **Result:**, and move the whole item to the end of its section in [completed.md](completed.md). Move what was learned into `docs/`. IDs are never reused, so pick the next one after the highest in either file. Work an item leaves undone stays here as its own item, cross-referenced by ID.

## 1. Fixes

### - [ ] F24. Sessions share the accessibility translator, but each brings its own bridge and read state (M, unverified)

- **Problem:** found in the architecture review (2026-11-24). `AXPTranslator.sharedInstance` has one `bridgeTokenDelegate`, but each `SimulatorAccessibility` has its own queue, `AccessibilityBridge` and `AccessibilityRead`. After a reboot, the daemon opens a new session, whose `prepare()` replaces the delegate while the old session's read, which can take up to 20 s, still runs on its own queue. That old read then goes through the new bridge, under the new read's deadline, and writes its failure into the new read from another thread: a data race on an `@unchecked Sendable` object.
- **Read:** `S:SimDriveNative/Accessibility/SimulatorAccessibility.swift` (`open`, `init`, `AccessibilityBridge`, `AccessibilityRead`), `S:SimDriveCore/Daemon/DaemonServer.swift` (`openSession`).
- **Do:** give the translator, its bridge and one serial queue a single owner for the whole process. Keep each read's state per request, keyed by the token the callbacks already receive.
- **Test:** reboot a simulator you created while `tree` runs in a loop through the daemon, then check that the next `tree` answers; run once with Thread Sanitizer (`swift build -c release --sanitize=thread`).

### - [ ] F31. The matrix fails a check on a retryable error right after a first boot (S)

- **Problem:** found with N6 (2026-11-25). On a new iPhone 17, iOS 27.2, booted while another new simulator booted, `setting bold-text on` failed with `tool-timeout` ("simctl spawn did not finish within 60 s") and the section went 46/47; rerun on the same simulator, 47/47. The first `simctl push` after a boot also takes ~52 s (N11). `setting_snapshot` already runs a read again when it says `retry`, but other checks do not, so a slow first boot fails checks that would pass.
- **Seen (2026-11-25, I18):** on a new iPhone 17, iOS 27.2, the first `tap` and `tap --no-daemon` failed with `guest-service-timeout` on the digitizer, and on a new Duo `posture half` with `posture-timeout` reading 0.0. Both sections passed on the same simulators rerun, and `posture` on a second new Duo.
- **Do:** in `sd()` (`Evaluation/matrix.py`), run a command once more when its response has `"retry": true`, and mark the check's detail with the first error so a retry stays visible rather than hidden. Leave commands whose retry changes the outcome, such as taps, to the check itself.
- **Test:** `Evaluation/fresh.py --only settings` on two new simulators booted at once.

### - [ ] F32. The matrix's crash check fails when another simulator crashed the probe recently (S)

- **Problem:** found with I18 (2026-11-25). The Mac's ReportCrash writes no new report for a repeat of the same crash, wherever it happened. On a new iPhone 17, iOS 27.2, the probe's `-probeCrash` wrote nothing because another simulator's matrix had crashed it at 15:25. The matrix's fallback, `logs --peek --source crash --since 24h`, then finds nothing, since `logs` rightly keeps only this device's reports, and `logs crash summary` fails. The check passes on a simulator whose probe crash is the first in a while.
- **Do:** make the probe's crash unique per run, such as by crashing in a function named after a random argument or with a varying stack depth, so ReportCrash never treats it as a repeat. Check `docs/open-questions.md` ("Repeated crashes") first: if a repeat can be told apart, `logs` itself should report it.
- **Test:** the matrix's `logs` section on two new simulators in a row.

## 2. Improvements to existing commands

### - [ ] I6. Detect a sleeping display, and wake it (M, steps 1 and 2 done; step 3 blocked on reproducing sleep)

**Step 3 attempt (2026-11-25):** not built, since idle sleep did not reproduce. On a new iPhone 17, iOS 27.2, `doctor` read `backlight` `on` and unlocked throughout: 130 s idle after launching the probe, 180 s after one tap in it, 90 s on the Home screen, and once 75 s after a tap with no reads in between. So what dims the display is unknown: the single `dimmed` read below may have come from something else in that run. **Next:** find a reliable trigger first (a simulator left idle much longer, one shown in Simulator.app or DeviceHub, older runtimes, or an Auto-Lock preference such as `SBAutoLockTime` in `com.apple.springboard`), then wake before input as step 3 says, checked against it.
**Lead (2026-11-25, while doing N8):** after `Evaluation/fresh.py --only tree,keys,buttons` on a new iPhone 17, iOS 27.2, `doctor` read `dimmed` and unlocked a minute or so later, and screenshots stayed on the dimmed frame through `launch`, a tap and `button keyboard`, while `tree` answered. The buttons section ends with `lock`, `lock`, an edge swipe, `siri` and `home`, so one of those presses likely starts the idle timer that a fresh boot does not: try them one at a time, then idle.

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

### - [ ] I12. Read the Duo's Home screen from the active panel only (M)

- **Problem:** on a Duo's Home screen, `tree` mixes both panels. Open, on iOS 27.2 (`688B6C57`), it returned 26 VoiceOver elements, 13 of them duplicates (Safari, Messages, Options, the clock), with points from -0.43 to 2.42. Closed was alike. Apps are not affected: the probe's tree is right either way.
- **Measured:** the display ID passed to `frontmostApplicationWithDisplayId:` changes nothing: 0, 1 and 3 return the same tree, open and closed, so the planned fix does not work. SpringBoard's top-level windows (open, interface 951×669 points) come in four sizes, each at the origin: the inner panel in native portrait points (669×951) and pixels (2007×2853), and the outer panel in points (466×678) and pixels (1398×2034). AXe handles three problems, all needed (`A:Packages/IDBKit/FBSimulatorControl/Commands/FBAXInactivePanelWindowFilter.swift`, `FBAXTranslationRequest.swift:357-380`):
  1. **Other panel's windows.** Dropping top-level windows at the origin with the other panel's size, in points or pixels and either orientation, removed every labelled duplicate. The panels' sizes are in the device type's `capabilities.plist` (`displays`, `integrated`, `hasDigitizer`), or in `Screens`.
  2. **Native frames.** On a quarter-turned panel, SpringBoard's windows of the panel's native size keep native coordinates. Safari's raw point (0.3656, 0.0715) matches its dock icon at (0.95, 0.52) only after AXe's conversion: x = native height − y, y = x.
  3. **Icons with the other panel's frames.** Kept windows still list some icons at the outer panel's places: Calendar reads (0.06, 0.42), drawn at (0.525, 0.43). AXe asks each button for its display (one request per button, only when step 1 dropped a window) and drops those on another.
- **Do:** the three steps in `DeviceAccessibility`, with the windows' classification in `AccessibilityLayout`, which knows the panel; the per-button display request in `SimulatorAccessibility`. **Test:** `tree` on the Home screen of a closed and an open Duo, every point against the screenshot; the probe's tree unchanged; the matrix's posture section; time `tree` on the Home screen.

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

### - [ ] I24. Send keys over the digitizer connection instead of a keyboard service (S experiment, unverified)

- **Why:** found in the upstream review (2026-11-24). AXe sends `IndigoKeyboardButtonEvent {usageCode, state}` on the same `remote.hid.digitizer` XPC connection as its touches, creating no keyboard service and using no UniversalHIDKit observer. If keys reach apps that way in simdrive too, the guest might not count a hardware keyboard as connected, which hides the software keyboard and is half the reason inputs are released after 30 s, and `GuestKeyboard` would get simpler.
- **Read:** `A:Packages/IDBKit/FBSimulatorControl/HID/FBSimulatorDTUHIDTransport.swift:188-205 @1ffbd35`, `A:Packages/IDBKit/FBSimulatorControl/HID/DTUHIDModels.swift:76-91 @1ffbd35`. `IndigoKeyboardButtonEvent` is not a type CoreDeviceUtilities exports, even on 27.2 (checked with `nm`): AXe builds that XPC dictionary by hand (`XPCEncoder`), so simdrive would have to encode it the same way, outside its ABIBridge bindings. Check that the guest still takes it on Xcode 27.3, since F28's `IndigoButtonEvent` did not survive there.
- **Do:** a spike. Send one key that way on 27.2, check that the probe logs `KEY`, and check whether the software keyboard still shows for a focused text field. Adopt it only if both answers favor it. Then record the result in `docs/private-apis.md`.

### - [ ] I26. Check VoiceOver and color filters in the matrix, and say what VoiceOver changes about input (S)

- **Problem:** left from N20 (2026-11-24). `voiceover`, `color-filter` and `color-filter-intensity` are checked only by reading back through their own actions (the matrix's `guest_action_checks`, from I10) and one screenshot, not by the probe, unlike every other setting row (AGENTS.md "Adding a capability"). With VoiceOver on, taps may select instead of activate and keys may go to VoiceOver; nothing says what still works.
- **Read:** `Evaluation/Probe` (its `STATUS` line), `Evaluation/matrix.py` (`setting_checks`), `docs/design-decisions.md` ("Settings as a catalog").
- **Do:** log `UIAccessibility.isVoiceOverRunning` and the color filter status in `STATUS`, and check the three rows in the `settings` section. With VoiceOver on, run a `tap`, a `tap --label`, a key and `type`, and record in `docs/device-behavior.md` what reaches the probe.
- **Test:** the matrix on iOS 17.0 and 27.2; VoiceOver changes on both, the color filter on 27 only.

### - [ ] I28. Extend the settle wait of element taps (S, partly unverified)

- **Problem:** left from I27 (2026-11-25).
- **Unverified:** iPad, landscape and the Duo's other postures (the Duo's default posture passed the whole matrix). A text field with a blinking cursor under the point: the cursor toggles about every 500 ms, so 150 ms of stillness should fall between blinks; confirm it does not hit the 1.5 s bound.
- **Extras not done:**
  - `--no-settle`, for scripts that know the screen is still and want the ~160 ms back. Wait until someone asks.
  - An opt-in settle for `tap <x> <y>` and swipes.
- **Test:** run the matrix's `tap` section on an iPad and in landscape; time `tap --id` with `--timing` against the release before F29.

## 3. New features

Each new command needs a `Command` case, parsing, usage text, results JSON, an error code where it can fail, parser tests, a README row and a skill line, per AGENTS.md's "Adding a capability".

### - [ ] N5. `biometrics enroll|unenroll|match|fail` (S)

- **Do:**
  - **Match and fail:** post `com.apple.BiometricKit_Sim.<source>.match` or `.nomatch`. The source is `pearl` (Face ID), `fingerTouch` (Touch ID) or `oyster` (Optic ID) (`N:NeoSimulatorKit/Simulator/Session/DeviceSession.swift:957-978`).
  - **Enrollment:** set the state of `com.apple.BiometricKit.enrollmentChanged` with `darwinNotificationSetState:name:error:` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:330`), then post it. See NeoSimulator's enrollment code next to line 957 for the state values.
  - Choose the source from the device type, or with `--type`.
- **Test:** the probe adds a "Biometrics" button that calls `LAContext.evaluatePolicy` and logs `BIO ok|fail`. Check enroll, then match, then fail.

### - [ ] N7. Core Animation debug colors (S)

- **Do:**
  - Settings rows `color-blended-layers` (option 2), `color-copied-images` (1), `color-misaligned-images` (14) and `color-offscreen-rendered` (17), through `SimDevice setCADebugOption:enabled:` and `getCADebugOption:` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:348-352,1078-1083`; `N:NeoSimulatorKit/Simulator/Input/HIDInput.swift:83-99`).
  - Errors are not reported, so read the value back.
  - This needs a setting kind for SimDevice-backed values in `SettingCatalog`.
- **Test:** toggle each option and read it back; a screenshot of the probe shows the tint. Add a matrix check of the read-back.

### - [ ] N10. `location set <lat> <lon>|run <scenario>|clear|list` (S)

- **Do:** `simctl location <udid> set <lat>,<lon>`, `run <scenario>` and `clear`, as NeoSimulator does (`N:NeoSimulatorKit/Devices/DeviceSettingsBackend.swift:333-345`). Use `availableLocationScenarios` on `SimDevice` for `list` (`N:NeoSimulatorDeviceIO/Simulator/CoreSimulator.swift:357-367,1140-1166`), or `simctl location list` if it exists.
- **Test:** the probe adds `CLLocationManager` updates (with `NSLocationWhenInUseUsageDescription`, after granting with N11's `privacy`) and logs `LOCATION lat lon`.

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

## Not planned

- **Scroll wheel and trackpad gestures:** the guest drops them unless they come from a real Mac HID device (`N:NeoSimulatorPresentationAdapters/Native/CoreDeviceScreenInput.swift:318-319,388`). Drags already scroll.
- **NeoSimulator's control-socket CLI (#619):** it offers only `logins` and `sign-in`, and needs the NeoSimulator app running. N25 covers its use.
- **Screen connection, USB capture, virtual-machine client and device reports:** these serve physical devices (`N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceScreenConnection.swift`, `RemoteScreenCaptureSource.swift`, `CoreDeviceVirtualMachineClient.swift`, `N:NeoSimulatorKit/Devices/DeviceReports.swift`). `logs` already reads simulator crash reports.
- **Video recording through CoreDevice:** `simctl io recordVideo` covers simulators. N28 plans `record start|stop` over `simctl` (stopped with SIGINT, waiting for "Recording started", as `N:NeoSimulatorKit/Simulator/Capture/VideoRecording.swift:56-96` does).
- **An XCTest runner inside the simulator, as agent-device uses:** each touch costs 0.7–3.7 s, and a cold start may build the runner with `xcodebuild` (`D:apple/runner/RUNNER_PROTOCOL.md`, `D:docs/evidence/ios-other-paths-latency-2026-10-19.md`). simdrive's guest services answer in milliseconds.
- **An LLM agent loop, React Native tooling, device clouds and physical devices** (AXe's `agent`, agent-device's `react-devtools` and remote sessions): outside simdrive's job of driving simulators for an agent that already exists.
- **External displays, CarPlay and audio routing:** costly, and of little use to agents.
