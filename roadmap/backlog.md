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

- **Source comparison of 2026-11-25**: items and notes from it cite NeoSimulator at `c9710cf`, AXe at `581c5b7`, idb at `62b1bce` (with its new `FBSimulatorAX` module), agent-device at `24f8181`, WebDriverAgent (`W:`) at `30aac06`, fastlane at `d7df171` and Maestro at `46ebef7`, each with `@<commit>` where it matters. Numbers quoted from them are their own measurements, from code comments, READMEs and changelogs, unless an item says simdrive measured it.

- **Every item** follows [AGENTS.md](../AGENTS.md): "Adding a capability" for structure, the README and skill for docs, and [docs/](../docs) for what was learned. Verify on simulators you created with `swift build -c release`, then `Evaluation/matrix.py <udid>`. Measure speed claims with `--timing --label <name>` before and after (`SIMDRIVE=<path>` runs another build).
- **Unverified** marks a claim taken from NeoSimulator's code or CoreSimulator's strings that nobody has run in simdrive.
- **When an item lands**, in the commit that lands it: tick it, add its **Result:**, and move the whole item to the end of its section in [completed.md](completed.md). Move what was learned into `docs/`. IDs are never reused, so pick the next one after the highest in either file. Work an item leaves undone stays here as its own item, cross-referenced by ID.

## 1. Fixes

### - [ ] F31. The matrix fails a check on a retryable error right after a first boot (S)

- **Problem:** found with N6 (2026-11-25). On a new iPhone 17, iOS 27.2, booted while another new simulator booted, `setting bold-text on` failed with `tool-timeout` ("simctl spawn did not finish within 60 s") and the section went 46/47; rerun on the same simulator, 47/47. The first `simctl push` after a boot also takes ~52 s (N11). `setting_snapshot` already runs a read again when it says `retry`, but other checks do not, so a slow first boot fails checks that would pass.
- **Causes found upstream (2026-11-25, source comparison), which make some of these fixable in simdrive rather than retried by the matrix:**
  - **The digitizer's daemon is not up yet.** `dtuhidd` starts on demand; early in a boot it asks CoreAnimation for displays, aborts when none is up, and launchd throttles its respawn for 10 s, while the service lookup still returns a port and every send is dropped. idb probes a fresh connection with a barrier, 4 s per attempt, 4 s backoff, 5 attempts, a new lookup each time, and measured a daemon answering about 19 s after boot, past simdrive's 10 s `guestServiceLimit` (`I:FBSimulatorControl/HID/SimulatorDTUHIDConnection.swift:14-37,72-121`). AXe waits until `launchd_sim` has been up 10 s and `dtuhidd` is its child, and found that reconnecting on a long-running simulator made input worse, so it retries once at most (`A:Sources/AXe/Utilities/HIDBrokerReadiness.swift:51-60`, `A:docs/release-readiness.md:100`). For simdrive: in `GuestTouchscreen.open`, retry an opening barrier that times out only while the boot is young (or no `dtuhidd` runs), with a short timeout, a backoff and a fresh lookup; keep the single 10 s wait otherwise. idb also pays a ~200 ms "device-open tail" after the first barrier before handing out the connection (`:174-182`), likely F17's 215 ms.
  - **launchd_sim refuses work around a boot.** It answers error 124 ("Domain is tearing down") for a few seconds; NeoSimulator retries after 1, 2, 4 and 8 s (`N:NeoSimulatorKit/Devices/BackgroundServices.swift:354-355,556-562`). Recognize it in `DeveloperTools.simctl` as a fast retryable error. Its notes that disabling `nanoregistryd` "hangs every simctl operation" (`:303-311`) are a candidate for the 60 s `simctl spawn` hangs (unverified).
  - **Preferences can be read without the guest.** I30 reads them from the host's plist, which would end the `setting` read timeouts.
- **Seen (2026-11-25, I18):** on a new iPhone 17, iOS 27.2, the first `tap` and `tap --no-daemon` failed with `guest-service-timeout` on the digitizer, and on a new Duo `posture half` with `posture-timeout` reading 0.0. Both sections passed on the same simulators rerun, and `posture` on a second new Duo.
- **Do:** in `sd()` (`Evaluation/matrix.py`), run a command once more when its response has `"retry": true`, and mark the check's detail with the first error so a retry stays visible rather than hidden. Leave commands whose retry changes the outcome, such as taps, to the check itself.
- **Test:** `Evaluation/fresh.py --only settings` on two new simulators booted at once.

### - [ ] F34. Edge swipes on iOS 17.0 through UniversalHID's digitizer edge bits (S, spike)

- **Why:** left from F16 (2026-11-25). idb and AXe send edges the way simdrive does, `IndigoDigitizerEvent.edge` on the digitizer service, and none claims iOS 17 works (`I:FBSimulatorControl/HID/SimulatorHIDEvent.swift:185-193`); SimulatorKit's legacy Indigo edge path is suppressed by CoreSimulator 1155.4 and later (`I:SimulatorHIDTransportSelection.swift:36-45`). NeoSimulator sends real HID digitizer reports instead: `UniversalHID.DigitizerReport` contacts with `setContactSwipeUp/Down/Left/Right(true, atIndex:)` to `HIDServiceID.mainTouchscreen` after creating a `touchscreenGesture` service (`N:NeoSimulatorPresentationAdapters/Native/CoreDeviceHIDReports.swift:53-73`, `GuestScreenInput.swift:77-121`). iOS 17's backboardd may honor those.
- **Do:** spike one bottom-edge swipe that way on a new iPhone 15, iOS 17.0; if it goes home, use it there (or everywhere, after the matrix). Overlaps N22. idb's in-guest `AXSpringBoardServer.unlockDevice` unlocks without a swipe but needs guest code.

### - [ ] F35. Hit tests and missing icons on the Duo's Home screen (S–M, hit tests done)

**Result so far (2026-11-25), on a new iPhone Duo, iOS 27.2:** hit tests are fixed. The display and point simdrive passed were right: open, the guest answered with SpringBoard's element, but in the panel's native, unturned frame (the clock at (30, 27) for a point at the top right), which `layout.contains` rejected. `PanelWindows.hitElement` now keeps an element whose frame holds the point as read, turns it from native coordinates when only the turned frame does (on a quarter-turned panel), and drops one reporting another display; `tree` gets the same conversion from its windows. Open, `tree x y` found Safari, Messages, Options, the clock, Calendar, Photos and Settings, each at its drawn place; closed, Safari, the clock, and Fitness, Watch, Files, Contacts and AXProbe on the second page, where Files and Contacts are missing from `tree`. The matrix's `tree,tap` passed 55/55 on a new Duo. **Left:** the icons missing from `tree`, and the closed Search element.

- **Why:** left from I12 (2026-11-25, iPhone Duo, iOS 27.2).
  - **Open, hit tests find nothing:** `tree 0.95 0.52`, Safari in the dock, returns `no-element`, though `tree` lists Safari there. AXe passes the panel's `screenID`, checked against CoreDevice's `getdisplayinfo`, and a point in the panel's native, unturned points (`A:FBSimulatorAccessibilityCommands.swift:97-108`, `A:FBAXTranslationRequest.swift:331-337`); `DeviceAccessibility.element(at:)` may pass the wrong display or an unturned point.
  - **Icons with only the other panel's views:** SpringBoard gives some icons the other panel's views (display 3), which I12 drops, so drawn icons are missing from `tree`. Which ones varies by boot: closed, one Duo lacked Calendar, Photos, Maps, News and Health, another only Photos, Maps and Health. AXe's 9dfd60d says such icons are in no tree and "can only be tapped by coordinates".
  - **Closed, the inner panel's Search** stays at (2.29, 0.12) with no display, outside the cover.
- **Do next:** decide with the user whether `tree` should fill in icons the snapshot lacks from hit tests (a grid over the Home screen, as idb does for other processes' content: slower, and a change to what `tree` returns), or keep documenting that `tree x y` finds them. Drop the Search element if a rule other than its frame tells it apart (its window, or a display read for it alone); an element outside the screen is otherwise legitimate, as in a scrolled app.
- **Test:** `tree` on the Home screen, open and closed, against the screenshot; the matrix's `tree,tap,posture`.

### - [ ] F38. After closing an open Duo, the cover can stay black (S, unverified)

- **Seen (2026-11-25, iPhone Duo, iOS 27.2, while doing F35):** after `posture open`, a few hit tests, and `posture closed`, the hinge read closed at 0°, but `simctl io screenshot --display 1` gave a black landscape image (2034 × 1398) for over a minute, while display 3 kept drawing the Home screen; `tree` placed icons as if open. An open and a close again did not help; `button home` and another `posture closed` some minutes later did, and the cover drew in portrait. The matrix's posture section passed meanwhile: it checks the screenshot's display index, not what it shows.
- **Do:** reproduce with a run of open and close; then wait in `Hinge.set` for the guest to move its scene to the right display (as idb waits for the display layout to settle, F35's upstream notes), or fail. Make the matrix's `screenshot follows closed` check that the cover's screenshot is portrait and not black.
- **Test:** the matrix's `posture` section with the new check, several runs on a new Duo.

### - [ ] F36. `privacy grant photos` has no effect an app sees on iOS 17.0 (S)

- **Seen (2026-11-25, whole-matrix run at 0d2c5fa):** on a new iPhone 15, iOS 17.0, the matrix's `privacy grant photos` fails three runs in three: the probe logs `PHPhotoLibrary.authorizationStatus(for: .readWrite)` 0 (not determined) after a relaunch, though the guest's `TCC.db` holds `kTCCServicePhotos|com.simdrive.axprobe|2` (allowed). `xcrun simctl privacy … grant photos` followed by `simctl launch --terminate-running-process` does the same, so simctl itself, not simdrive, is ineffective there. iOS 27.2 passes.
- **Do:** check whether iOS 17's Photos reads a limited-library or `kTCCServicePhotosAdd` row, needs photolibraryd restarted, or reads `.addOnly`; then either make `privacy` work there or fail it with a named error on runtimes where it has no effect, and list the runtime in the README.
- **Test:** the matrix's `services` section on a new iPhone 15, iOS 17.0.

### - [ ] F37. Element taps can go ahead before a sheet starts moving on iOS 17.0 (S–M)

- **Seen (2026-11-25, whole-matrix run at 0d2c5fa):** on a new iPhone 15, iOS 17.0, `tap --label right after a sheet transition` delivered 1 of 3 in two runs of three: the two dropped taps settled after 184 and 177 ms, against about 600 ms when delivered. The pixels under Done held still for 150 ms before the sheet began to slide in, so `Stillness` called them settled. The push transition delivered 3 of 3 each time, and iOS 27.2 passes.
- **Do:** I33's accessibility idle signal would answer this directly; short of it, require that the tree's element and the pixels agree (the patch at its point changed at least once, or matches what the element draws) before calling the screen still. Measure on iOS 17.0 and 27.2 that a still screen keeps its ~160 ms.
- **Test:** the matrix's `tap` section, three runs on a new iPhone 15, iOS 17.0.

## 2. Improvements to existing commands

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
- **Seen (2026-11-25, F33):** idb's own XPC connection to `com.apple.CoreSimulator.accessibility` drops on invalidation and reconnects on the next read, so `launchctl kickstart -k system/com.apple.CoreSimulator.bridge` recovers without a new daemon (`I:FBSimulatorAX/Translation/AXTranslationTransport.swift:154-199`): a new private wire shape to decide on with the user. idb's stall probe (`I:Translation/AXStallProbe.swift`) samples the target's CPU and syscalls 250 ms into a stalled read, a template for F15's research. idb also bounds reads at depth 50 and 3000 nodes with a `truncated` flag, against simdrive's 500 and 10,000.

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
- **Seen (2026-11-25, source comparison):** idb sends keys the same way, `IndigoKeyboardButtonEvent {usageCode, state 1 down / 2 up}` on the digitizer connection, and its liveness barrier is that message with usage 0 and `isBarrier` (`I:SimulatorDigitizerHIDTransport.swift:152-157`, `I:SimulatorDTUHIDConnection.swift:235-242`). AXe measured 30 characters in 0.13–0.17 s and one key in 0.11 s with no gap per key (`A:CHANGELOG.md:53-66`). The gain for simdrive is the first key: no `createService` round trip and no 400 ms `GuestInputTiming.settle`. Whether the software keyboard still shows is documented nowhere.

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

### - [ ] I29. Read and set the hinge through the guest's own services, not CoreDevice (M, unverified)

- **Why:** found in the source comparison (2026-11-25). `posture` waits on `CoreDeviceRemote`, whose first call blocks 10–40 s after a boot, and `posture-timeout` showed up on new Duos (F31). AXe reaches the guest directly: `SimDevice lookup:` of `com.apple.coredevice.feature.monitormotion` to read and of `…remote.hid.vendordefined` to write, connected with `xpc_endpoint_create_mach_port_4sim`, `xpc_connection_create_from_endpoint` and `xpc_connection_enable_sim2host_4sim`; writes are an `IndigoVendorDefinedEvent` with usage page 0xFF61, usage 0x5B; reads have a 3 s budget; and it keys on `launchd_sim`'s pid and start time so a reboot mid-call fails cleanly (`A:Packages/IDBKit/FBSimulatorControl/HID/FBSimulatorHIDMotionFeed.swift:87-104`, `A:FBSimulatorHingeNative.swift:16,76-134`, `A:FBSimulatorHingeReader.swift:13-23@581c5b7`). AXe is GPL: reimplement the mechanism, do not copy code.
- **Read:** `S:SimDriveNative/DeviceControl/CoreDeviceHinge.swift`, `S:SimDriveCore/DeviceControl/Hinge.swift`, `S:SimDriveNative/Guest/SimulatorGuest.swift` (how `Guest*` drivers connect).
- **Do:** a `GuestHinge` driver in `DeviceControl/` with `open(guest:)` returning nil without the services, and `Hinge` on it; drop `CoreDeviceHinge` once the matrix's `posture` passes on new Duos.
- **Test:** `Evaluation/fresh.py --device 'iPhone Duo' --only posture` three times; time the first `posture` after `bootstatus` before and after.

### - [ ] I31. Call CoreSimulator in process instead of `simctl` for status bar, location, privacy, push and URLs (S–M, unverified)

- **Why:** found in the source comparison (2026-11-25). `SimDevice` has `overrideStatusBar*`, `clearStatusBarOverrides:error:` and the current overrides (for N11's missing `status-bar list`), `setLocationWithLatitude:andLongitude:error:` and `availableLocationScenarios` (for N10), `setPrivacyAccessForService:bundleID:granted:error:`, `sendPushNotificationForBundleID:jsonPayload:error:` and `openURL:` (`I:PrivateHeaders/CoreSimulator/SimDevice.h:235-315`; idb calls the status bar and location ones, `I:Commands/SimulatorStatusBarCommands.swift:24-90`, and retries `openURL` twice). Each saves about 0.1 s of `simctl` and gives typed errors; the 52 s first push and slow permission alerts are guest-side and stay.
- **Do:** start with `status-bar list` and N10's location, which need new calls anyway; move the others only if `--timing` shows the saving matters.

### - [ ] I32. Close the guest's connections without waiting, and try taps without a hold (S, unverified)

- **Why:** found in the source comparison (2026-11-25). simdrive holds a tap 60 ms and sleeps 300 ms in `close` to drain. idb taps with no hold (down, then up at once, `I:SimulatorHIDEvent.swift:86-91`) and drains 80 ms; AXe holds 100 ms but schedules the connection's cancel 380 ms after the last message instead of sleeping (`A:FBSimulatorDTUHIDTransport.swift:65-73,423-438`). idb's opt-in 150 ms deceleration keeps a scroll from coasting past a swipe's end, never for edge gestures (`I:SimulatorHIDEvent.swift:163-169`).
- **Do:** schedule `GuestConnection`'s cancel after the drain rather than awaiting it, saving up to 300 ms on `--no-daemon` and `stop`; measure a 0 ms tap hold against the matrix's `tap` checks before adopting it.

### - [ ] I33. Wait for the app to be idle through accessibility rather than pixels (M, spike)

- **Why:** found in the source comparison (2026-11-25). idb's in-guest bridge turns on automation mode, observes `kAXUserTestingNotification` (4002), and asks the app with action 0x7fa (monitor the idle run loop) or 0x7fb (detect animations finished); the app answers `RunLoopIsIdle` or `AnimationsNonActive`, and posts `TouchEventsCompleted` after each touch sequence (`I:SimulatorFrameworkBridge/Runtime/Private/AXRuntimePrivate.h:86-114`, `I:SimulatorFrameworkBridge/Swift/AccessibilityQuiescence.swift:193-249`). It is the signal XCTest's `waitForQuiescenceIncludingAnimationsIdle` uses. `TouchEventsCompleted` would also confirm that a tap was delivered, which no simdrive check does.
- **Do:** spike whether the Mac's translator can perform 0x7fa/0x7fb on an app element and receive 4002; idb used a helper in the guest. Compare with `Stillness` on the F29 alert and I27's sheet. Automation mode is device-wide and turns off when another client exits; apps with endless animations never go idle, so keep a bound (agent-device caps XCTest's wait at 1 s).

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

### - [ ] N33. `alert` on iPad, for action sheets, and in other languages (S, unverified)

- **Problem:** left from N29 (2026-11-25). `alert` was checked only on an iPhone 17, iOS 27.2, in English, with `.alert`-style alerts.
- **Unverified:** an iPad's alert view, expected to be `_UIAlertControllerView`, which `AlertReader` also accepts; an action sheet (`.actionSheet`), whose cancel button may sit apart from the others, and on iPad in a popover; alerts from other system services, such as location ("Allow While Using App"), tracking and notifications; and labels in other languages, where only the permission identifiers and UIKit's order help, since the label lists are English.
- **Do:** add an action sheet to the probe, run the matrix's `tap` section on an iPad, and try `alert accept|dismiss` with the simulator's language set to another one. Add labels or rules only where the order fallback picks wrong.
- **Found upstream (2026-11-25, source comparison):**
  - **Localized labels without a list per language:** agent-device reads the simulated OS's own string tables from the runtime and maps each localized label back to English: `PrivateFrameworks/UserNotificationsServer.framework` and `PrivateFrameworks/TCC.framework` Localizable, `Frameworks/CoreLocation.framework` locationd, `Frameworks/CoreServices.framework` SchemeApproval (`D:RunnerSystemPromptStrings.swift:12-25`, `D:RunnerAlertLabelVocabulary.swift@24f8181`). simdrive can read the same files under the runtime's RuntimeRoot on the Mac.
  - **Ties and confirmation:** agent-device refuses a tie instead of picking, waits until the button is hittable, then re-reads to confirm the alert went or changed, reporting "unconfirmed" otherwise (`D:RunnerAlertButtonChoice.swift:1-45`).
  - **Sheets and iPad:** WebDriverAgent finds alert, sheet and scroll-view candidates in one query, ignores a sheet inside a `PopoverDismissRegion` on iPad, detects Safari's in-page dialogs, and for accept takes an alert's last button but a sheet's first (`W:WebDriverAgentLib/Categories/XCUIApplication+FBAlert.m:85-185`, `W:FBAlert.m:255-280`). agent-device counts a surface on a foldable only inside its hosting window (`D:AlertSurface.swift:45-74`).
  - **Done already:** `dismiss` no longer falls back to button order, after agent-device's issue #3627, where a guessed position granted a permission.

### - [ ] N30. Install simdrive with Homebrew, and the skill with `simdrive init` (M)

- **Read:** AXe ships `brew install cameroncooke/axe/axe`; the formula ad-hoc signs the binary and frameworks after install, and CI signs and notarizes releases (`A:scripts/generate-homebrew-formula.sh:62-91`, `A:.github/workflows/release-shared.yml:151-269`). The skill is embedded in the binary, and `axe init` installs it; Claude and Codex plugin manifests sit in `A:agent-plugin/`.
- **Do:** a tap with a formula building from source with Xcode 27; `simdrive init [cursor|claude|<dir>]` writing the skill with this binary's path in place of `<simdrive>`, replacing the manual steps in AGENTS.md.

### - [ ] N31. An in-guest accessibility helper (L, unverified)

- **Why:** reading through `AXPTranslator` costs a round trip per element, sees only the frontmost app, and depends on the guest's accessibility server (F7, F15).
- **Read:**
  - idb's `axbridge` backend runs a helper inside the guest, reached over a Unix socket. It returns the whole tree in one round trip, sees content drawn by other processes, asserts automation mode, and reports modals (`I:FBSimulatorAX/README.md:15-100`, `I:SimulatorFrameworkBridge/`).
  - agent-device compiles a helper with `xcrun --sdk iphonesimulator clang`, starts it with `simctl spawn <udid> … serve <socket>`, and snapshots through `XCTAccessibilityFramework`'s `userTestingSnapshotForElement:`: warm snapshots take 8.6–118 ms (`D:apple/snapshot-bridge/README.md:10-24`, `D:docs/evidence/ios-snapshot-adr-0004-measurements-2026-11-06.md:25-27`).
- **Do:** prototype the helper as a separate target built for the simulator SDK, spawned by the session; compare speed, coverage and failure modes with the translator before switching `tree` to it.

### - [ ] N34. `--no-wake` for touch input and rotation (S)

- **Why:** left from I6 (2026-11-25). Input now wakes a dimmed display first, pressing Lock. An agent that tests what a dimmed or sleeping display does with a touch cannot send one.
- **Do:** a `--no-wake` flag on `tap`, `swipe`, `pinch`, `rotate`, `alert` and `orientation`, passed to `DisplayWake`; parser tests, README and skill. Only if someone asks for it.

## Not planned

- **Scroll wheel and trackpad gestures:** the guest drops them unless they come from a real Mac HID device (`N:NeoSimulatorPresentationAdapters/Native/CoreDeviceScreenInput.swift:318-319,388`). Drags already scroll.
- **NeoSimulator's control-socket CLI (#619):** it offers only `logins` and `sign-in`, and needs the NeoSimulator app running. N25 covers its use.
- **Screen connection, USB capture, virtual-machine client and device reports:** these serve physical devices (`N:NeoSimulatorDeviceIO/CoreDevice/CoreDeviceScreenConnection.swift`, `RemoteScreenCaptureSource.swift`, `CoreDeviceVirtualMachineClient.swift`, `N:NeoSimulatorKit/Devices/DeviceReports.swift`). `logs` already reads simulator crash reports.
- **Video recording through CoreDevice:** `simctl io recordVideo` covers simulators. N28 plans `record start|stop` over `simctl` (stopped with SIGINT, waiting for "Recording started", as `N:NeoSimulatorKit/Simulator/Capture/VideoRecording.swift:56-96` does).
- **An XCTest runner inside the simulator, as agent-device uses:** each touch costs 0.7–3.7 s, and a cold start may build the runner with `xcodebuild` (`D:apple/runner/RUNNER_PROTOCOL.md`, `D:docs/evidence/ios-other-paths-latency-2026-10-19.md`). simdrive's guest services answer in milliseconds.
- **An LLM agent loop, React Native tooling, device clouds and physical devices** (AXe's `agent`, agent-device's `react-devtools` and remote sessions): outside simdrive's job of driving simulators for an agent that already exists.
- **External displays, CarPlay and audio routing:** costly, and of little use to agents.
