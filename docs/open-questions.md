# Open questions

- **Upside-down interface.** `uiOrientation` 2 was never observed, so `portraitUpsideDown` mapping is untested. An iPad with an app that supports it would settle it.
- **Scenes and windows.** CoreSimulator reports one interface orientation per screen. Whether it follows the active scene when an iPad shows several windows in different orientations is unknown.
- **Display sleep.** simdrive neither detects nor prevents the iPhone simulator's idle display sleep. A wake step before input, or a guest preference that disables the idle timer, may remove the need for the lock, lock, swipe workaround.
- **Accessibility actions.** `AXPress` and `AXIncrement` through the translator would act on elements by label instead of by point; untried.
- **VoiceOver output and audits.** The guest's `axauditd` speaks DTX over XPC; no client exists yet.
- **Apple TV Remote swipes.** The touch surface is unsupported. NeoSimulator sends `IndigoHIDMessageForTrackpadMoveEvent` through SimulatorKit, the path that stopped delivering keys on Xcode 27; whether it still delivers swipes is untested.
- **Faster screenshots.** Every screenshot spawns `simctl io screenshot`. Reading the framebuffer in process, through the same screen adapter that reports orientation, could be faster; untried.
- **Repeated crashes.** ReportCrash writes no new report for a repeat of the same crash; it updates the earlier report's modification time, but also rewrites old reports for other reasons. Telling a repeat apart, so `logs` could report it, is unsolved.
- **Crash reasons.** Simulator reports leave `asi` without a Swift `fatalError` message, so `reason` is usually null. Whether another field or the log holds it is unchecked.
- **Private log values.** The unified log shows `<private>` for values not logged as public. Whether `log config` in the guest can lift that for a simulator is untried.
- **Flaky scroll check.** The matrix's `swipe scrolls` fails intermittently under load with no fix yet; whether the guest drops part of the drag or the check reads too early is unknown.
