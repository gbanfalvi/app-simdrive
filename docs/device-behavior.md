# Device behavior

Observed on Xcode 26.6 to 27.2 with iPhone iOS 17.0 to 27.2, iPhone Air iOS 26.0 to 27.2, iPad iOS 26.5 to 27.2, iPhone Duo iOS 27.1 and 27.2 and Apple TV 4K simulators.

## Timing

- A fresh process spends about 2 s resolving bindings before its first command (`doctor`: 1.6 s on an iPhone and 1.8 s on a Duo iOS 27.2, from 3.0 s and 3.7–5.7 s before ABIBridge 0.20.4); a warm daemon answers in tens of milliseconds.
- `simctl launch` returns 2.3–6 s before the app's scene is active. On a freshly booted simulator, with several others booted, apps took 20–67 s to come to the front.
- The accessibility server's frontmost pid matches the app's `SCENE active` to within about 0.3 s, which makes it a reliable launch signal.
- `tree` is bimodal: about 290 ms right after a launch or during animation, 25–150 ms otherwise.
- For about a minute after a simulator's first boot, the accessibility server answers slowly or not at all. A launching app answers with nothing, and any app occasionally does; simdrive retries three times, 0.5 s apart.
- On a cold iPhone boot (iOS 27.2), the main screen reports a started backlight about 85 s in, 25 s after its interface orientation, and the first `tree` after `bootstatus` took 3–30 s across five reboots.
- The guest ignores touches during transitions and batches events while busy, such as right after launch. For example, SpringBoard drops taps on the "Open in …?" URL alert for about 570 ms after presenting it (iPhone 17, iOS 27.2): backboardd hit-tests the touch to the alert's context, but SpringBoard's UIKit logs `shouldSend: 0; ignoreInteractionEvents: 1` for it until the present transition ends ("Alert layout appears correct"). A second `openurl` with the alert still up presents it again, with the same window. The alert's accessibility frame is final from the first read, but its pixels change until the window ends, so element taps wait for them to hold still ("Element taps wait for still pixels" in `design-decisions.md`, F29). An app's own page sheet drops taps the same way while it slides up (iPhone 17, iOS 27.2: three of three dropped without the wait, delivered after 279–361 ms with it); a navigation push did not drop them (I27). To see it: `simctl spawn <udid> log stream --level debug --predicate 'process == "SpringBoard" AND category == "EventDispatch"'`.
- The first CoreDevice command after `simctl boot`, such as `pasteboard`, blocks for 10–40 s, and CoreDevice is connected by the time it answers (iPhone iOS 17.0 and 27.0, Duo iOS 27.1, Apple TV tvOS 26.2).

## iPhone and iPad

- **Idle display sleep.** The iPhone simulator's display dims and sleeps when idle, as SpringBoard's idle timer allows. On an iPhone 17, iOS 27.2, `doctor`'s `backlight` once read `dimmed` after 20 s idle, though on a new one it stayed `on` for 75–180 s idle in the probe and on the Home screen, so the trigger is unknown (I6); `button lock` then locked it and the backlight stayed `dimmed` (not `off`) 5 s later, and a second press woke it to `on`, still locked until the edge swipe. While asleep, rotations and the first touch are dropped, and screenshots freeze on the dimmed frame. A new one read `dimmed` after about 5 minutes idle following a whole matrix run. From `dimmed` and unlocked, the first `lock` press locks it and reads `dimmed` within 1 s; the second reads `on` about 1 s later, locked; the edge swipe reads unlocked more than 0.5 s after it. `DisplayWake` runs that sequence before touch input and rotation, unlocking only a device that was unlocked.
- **Unlocking.** Without a passcode, the same `lock`, `lock`, edge swipe sequence returns to the app.
- **Notifications after boot.** On an iPhone 17, iOS 27.2, the first `simctl push` after a boot took 52 s before the guest delivered it, and later ones 0.3 s; an app's notification permission alert also showed 39 s, and once over 90 s, after launch. `simctl push` fails with UNErrorDomain 2003, "Source is not authorized", for an app without notification permission, though `userNotificationCenter(_:willPresent:)` still runs in an app in front (N11).
- **Status bar overrides** change only what the status bar draws: accessibility still reads the real time.
- **Covered elements stay in the tree.** With an app's own alert up, `tree` lists the screen behind it and the alert's elements after (iPhone 17, iOS 27.2). The full tree shows why: the window holds one `UITransitionView` per presentation, the alert's last, with its dimming views. A tap outside the alert reaches nothing behind it, yet a hit test there still answers with the element underneath, so hit tests alone cannot tell covered elements; `tree --covered` uses the layers (I8). A system alert, such as a permission request, makes SpringBoard the frontmost app instead, listing the status bar and the alert.
- **The Duo's SpringBoard holds both panels' windows.** Each top-level window sits at the origin, in this panel's points, the other panel's points, either panel's pixels, or, open, this panel's native unturned coordinates (iPhone Duo, iOS 27.2). simdrive keeps the first and turns the last (`PanelWindows`, I12). Kept windows still list some icons with the other panel's views and frames; snapshot attribute 2123 tells their display (3 for the inner panel, 1 for the cover), and simdrive drops them. Which icons varies by boot (closed: Photos, Maps and Health on one Duo, also Calendar and News on another), and their copies on the active panel are in no window, so the tree lacks them. Open, hit tests on the Home screen find nothing; closed, the inner panel's Search reads at x 2.29 with no display (F35).
- **Alerts look alike.** An app's own alert and SpringBoard's system ones, such as a permission request, are both a `_UIAlertControllerPhoneTVMacView` (view controller `UIAlertController` or `_SBAlertController`) labelled with the title, holding title and message labels, then the buttons (iPhone 17, iOS 27.2). Permission buttons carry identifiers such as `kTCCServicePhotos-allow-button`, `-deny-button` and `-limited-button`. A permission alert first shown after a boot took 40–90 s to appear (N29).
- **Background apps stop answering.** An app sent home is suspended within seconds; its accessibility read then goes unanswered until something shows it again. Behind a system alert it keeps answering.
- **A hidden software keyboard stays in the tree.** With a text field focused, `tree` lists the keyboard's keys (32 on an iPhone 17, iOS 27.2) whether it shows or not; hit-testing a point on it, as `tree 0.5 0.86`, finds a key only while it shows. `button keyboard` toggles it, and typing on the hardware keyboard hides it (N8).
- **More buttons** (iPhone 17, iOS 27.2): `action` toggles silent mode, shown as "Silent" in the Dynamic Island; `screenshot` takes the guest's screenshot and opens its editor; two `home` presses 150 ms apart open the app switcher. NeoSimulator's `side` (consumer 0x95) changed nothing visible and `apple-pay` (0x1BA) has nothing to show without Wallet, so simdrive leaves them out.
- **Going home.** A swipe up from the bottom goes home only with `--edge bottom`; the guest recognizes system gestures only for touches that start on an edge.
- **iOS 17.0 ignores edges.** On an iPhone 15, iOS 17.0 (Xcode 27.0), edge swipes reach the app as ordinary drags: backboardd logs the touch as `swipe-locked; behavior: foreground` and sends it only to the app, where iOS 18 and later mark it `sgp` (system gesture possible) and send it to SpringBoard's system gesture window too. Starting at y 1.0, a longer duration, a reboot and builds from before F17 changed nothing, and NeoSimulator sends the edge the same way. `button home` goes home and unlocks there instead (F16). 17.1–17.5 are untested.
- **Volume.** `volume-up` and `volume-down` show the volume HUD, and DeviceHub's volume changes, but apps' `AVAudioSession.outputVolume` stays put. Check volume presses by screenshot.
- **Connect Hardware Keyboard.** Turning it off with `SimDevice setHardwareKeyboardEnabled:false keyboardType:error:` does not stop simdrive's keys: its own main keyboard service still types. Tested on iPhone iOS 17.0 to 27.2, iPad iOS 27.2, iPhone Duo iOS 27.1 and Apple TV tvOS 26.2, with Xcode 26.6 to 27.2. The call succeeds, but no guest-side change was seen: `HardwareKeyboardLastSeen` stays 1 and the software keyboard stays hidden.
- **Full keyboard access.** While it is on, Tab and the arrow keys move focus instead of reaching the app.
- **Orientation.** The interface follows the device only when the foreground app supports that orientation, so it can differ from `orientation`'s reading. Face-up and face-down readings keep the last upright orientation for the interface.
- **Dynamic Island.** Screenshots show it as a black pill, since simdrive reads the unmasked framebuffer.
- **Upside down.** No tested device reported an upside-down interface; Face ID iPhones do not support it.

## iPhone Duo

- Hardware model `v68`. Two panels: the cover panel, `simctl` role `primary`, and the inner panel, `primary-1`, display 3 on the tested device.
- Closed, the inner panel's framebuffer is powered off and `simctl` screenshots it black; `simctl`'s display power does not unfold it. The closed cover panel's screenshots show its camera hole. Commands default to the cover panel when closed and the inner panel otherwise.
- The cover panel accepts orientation changes, but its apps stay portrait.
- A status strip with the clock takes the right of either panel, so apps span 0.83 of the cover panel's width and 0.92 of the inner panel's. Apps' `UIScreen.bounds` covers the app, not the panel, so a fraction of it is not a fraction of the screenshot.
- The inner panel's screenshots can be rotated relative to the panel while the device reads portrait. Mapping taps by device orientation alone flipped them 180° there, which is why simdrive reads the interface orientation per screen.
- The hinge animates toward the requested angle and settles near it, not on it.
- Ending an input connection within 500 ms of the last event lost the event on the Duo; 500 ms sufficed on single-display devices.
- A new session's touchscreen connection takes about 215 ms to handle its first message, later ones 0.1–0.3 ms. A drag sent unawaited arrived bunched, then held, and opened the app switcher.
- **Split view.** On the inner panel in landscape, dragging the home indicator up and to one side moves the app into that half, and dragging a half's indicator to the middle restores the whole screen. Tested with Settings and the probe on iOS 27.1 and 27.2, from a bottom edge touch:
  - Letting go while moving is a flick, and the app springs back. Holding, then lifting about 0.035 of the height before letting go, keeps a half.
  - Returning to the whole screen needs the hold at about y 0.925, a lift to 0.905 and a settle at 0.915; letting go on the lift opens the app switcher, and without the lift the app springs back to its half.
  - Sideways drags along the bottom switch apps, and lifting to about 0.90 opens the app switcher.
  - A split app's accessibility windows are 0.49 of the screen wide, against 1 for a whole-screen app, but start at x 0 in either half, so accessibility does not say which half. Its elements' frames start at the half's left edge, 0.5068 of the screen's width for the right half. Hit tests take screen points, and on the other half return the home screen's elements.
  - SpringBoard logs each layout it publishes as `_updateLayout <FBSDisplayLayout…>` (subsystem `com.apple.SpringBoard`, category `DisplayLayout`, default level), listing each element's frame and role in interface points: an app at `{{0, 0}, {469, 669}}` on the 951-point panel is on the left, at `{{482, 0}, {469, 669}}` on the right. When a drag opens the app switcher, `com.apple.springboard.app-switcher` is primary too.
  - SpringBoard handles the drag itself (`SBMainWorkspaceTransitionRequest`, `eventLabel: SBFluidSwitcherGesture`, `source: SystemGesture`). No guest service, SpringBoardServices request, accessibility action or Globe shortcut moves an app into a half; the accessibility split actions belong to the divider between two apps, which the app-and-Home split lacks.
  - On iOS 27.2, apps built with the iOS 27.1 SDK or later span the strip: 1 of the width in full, 0.4932 per half. Apps built with the 27.0 SDK leave it out, 0.917 in full and 0.409 in the right half, and report that window as their own frame. Both start each half at the same edge. On iOS 27.1, the probe left it out under either SDK, and Settings spanned it.

## Apple TV

- No digitizer and no orientation or pasteboard service. Remote buttons and the keyboard move and act on focus.
- `home` is the TV button and goes to HeadBoard, the home screen; `lock` opens Control Center; `menu` goes back.
- Settings has no focused element until the first `button down`.
- HeadBoard's tree may hold a single focusable element; test `tree` on Settings instead.
- CoreSimulator's interface options are unsupported, so `appearance`, `text-size` and `increase-contrast` read `unsupported`. The preference settings work.
- A quick relaunch of Settings can leave HeadBoard in front, which `launch` reports as `launch-not-frontmost`.
- While an app launches, `tree` can fail with `accessibility-translation` (no frame yet); retry after a second.

## Runtimes

- iOS 17 and 18 apps miss some accessibility changes unless the `com.apple.accessibility.cache.` notification follows the regular one.
- **App accessibility goes off with Full Keyboard Access.** On iPad iOS 27.0 and iPhone iOS 27.2, turning Full Keyboard Access off quits its process, and backboardd's `_AXNotificationObserverClientDied` then sets `ApplicationAccessibilityEnabled` to 0 within a second. Apps running keep answering; apps launched after that answer the frontmost-app request with an empty frame, so `tree` failed with `accessibility-translation` and `launch` with `launch-not-frontmost`. Writing the preference and posting `com.apple.accessibility.application.status` or `automation.enabled.status` does not wake such an app; a relaunch with the preference on, or starting an accessibility service, does. Turned off within about a second of turning it on, the process quits before registering and the preference stays on. iOS 17.0 keeps it on.
- The expanded-status accessibility attribute exists from iOS 18.
- `show-borders` also drives `AccessibilitySettings.showBordersEnabled` from iOS 26.1.
- `non-blinking-cursor` needs iOS 18; `glass-tint` needs iOS 26.
- `prefer-cross-fade` has an effect only while `reduce-motion` is on.
- iPhone Air and iPhone Duo end boots with a failed data migration (boot status 3), though the guest runs. Seen on Air iOS 26.0 to 27.2 and Duo iOS 27.1 and 27.2, under Xcode 26.6 to 27.2. Only the Air's first boot on iOS 27.0 finished normally. `simctl bootstatus` still exits 0, printing `Data Migration Failed`.
- On a second boot, status 3 comes 3–16 s in, before `Waiting on System App`, so `bootstatus` returns before SpringBoard is ready. Other iPhones wait for it, taking 11–17 s. Right after it returns, `tree` failed on 5 of 8 Air and Duo boots with `accessibility-timeout`, or under Xcode 27.2 with an orientation `guest-service-timeout`. That orientation timeout also failed one `screenshot`. After 90 s every command worked.
- **Accessibility after boot.** The first read starts the guest's accessibility server: on a Duo iOS 27.2 it took 10–11 s even 14 s after `bootstatus`. Its first answer comes about 3 s in, then it answers the frontmost-app request with no app for several seconds. Reads that gave up after 3 tries failed 3 of 3 boots; retrying to a 20 s deadline, the first `tree` succeeded on 7 of 7, in 14–18 s. An iPhone 18 Pro iOS 27.2 answered the first `tree` in 8–13 s even with 3 tries.
- **Screenshots after boot.** The first `screenshot` right after `bootstatus` took 10–14 s on a Duo iOS 27.2, mostly waiting 2.7–7.6 s for the guest's orientation. Screenshots now wait at most 1 s for it and report a null orientation past that.
- **Accessibility stuck until reboot.** Twice on a Duo iOS 27.2, every accessibility read went unanswered for minutes while the app was visible in front: `tree` failed with `accessibility-timeout` and `launch` with `launch-not-frontmost`, from fresh daemons and `--no-daemon` alike. Each read reached the guest's `CoreSimulatorBridge`, which logged it but never replied. A reboot cleared it both times; screenshots, taps and the hinge kept working. Not seen on an iPhone. See F15 in the backlog.

## Logs

- `log show --start @<seconds>` rejects fractional seconds, so simdrive starts at the whole second and filters the rest itself.
- `log stream` prints a `Filtering the log data…` header once attached. Ending `simctl spawn` with SIGTERM leaves the guest's `log stream` running; SIGINT ends both.
- `simctl launch --stdout` and `--stderr` paths resolve in the guest: `/tmp` is the device's own, so a host `/tmp` path fails silently.
- Without `NSUnbufferedIO=YES`, a Swift app's `print` output stays buffered until exit.
- About 98% of an app process's entries come from system libraries under `/System/`, `/usr/` or the runtime root.
- Values not logged as public read `<private>`.
- ReportCrash writes a crash report about 45 s after the crash, and only one per distinct crash: a repeat with the same signature updates the earlier report's modification time instead. It also rewrites older reports, so a modification time alone does not date a crash.
- A Swift `fatalError` message is not in simulator crash reports' `asi`; it appears on stderr.

## Hosts

- simdrive works with DeviceHub or NeoSimulator showing the device, or with neither.
- While simdrive holds the digitizer, clicks in DeviceHub do nothing; they work again 30 s after simdrive's last input, or after `stop`.
- DeviceHub syncs the guest's pasteboard with the Mac clipboard in both directions, so a simdrive pasteboard write replaces what the user copied.
