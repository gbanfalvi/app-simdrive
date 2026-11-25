# Open questions

- **Upside-down interface.** `uiOrientation` 2 was never observed, so `portraitUpsideDown` mapping is untested. An iPad with an app that supports it would settle it.
- **Scenes and windows.** CoreSimulator reports one interface orientation per screen. Whether it follows the active scene when an iPad shows several windows in different orientations is unknown.
- **Display sleep.** simdrive neither detects nor prevents the iPhone simulator's idle display sleep. A wake step before input, or a guest preference that disables the idle timer, may remove the need for the lock, lock, swipe workaround.
- **Accessibility actions.** `AXPress` and `AXIncrement` through the translator would act on elements by label instead of by point; untried.
- **VoiceOver output and audits.** The guest's `axauditd` speaks DTX over XPC; no client exists yet.
- **Apple TV Remote swipes.** The touch surface is unsupported. NeoSimulator sends `IndigoHIDMessageForTrackpadMoveEvent` through SimulatorKit, the path that stopped delivering keys on Xcode 27; whether it still delivers swipes is untested.
- **Repeated crashes.** ReportCrash writes no new report for a repeat of the same crash. It folds the repeat into an earlier report: the file gains the extended attribute `Multiple`, a little-endian UInt16 count, beside a `Signature` SHA-1, and its modification time moves to the repeat, while its JSON keeps the first crash's `captureTime`. That earlier report can belong to another simulator: a crash on one new iPhone raised `Multiple` on a report of device `3B30…` (2026-11-25, F32). So a repeat can be told apart, but not attributed to a device from the report alone; F32 plans to detect the crash from the guest's log. A per-process-name cap (25 reports, then none, even after deleting them) was seen on the host and is not understood.
- **Crash reasons.** Simulator reports leave `asi` without a Swift `fatalError` message, so `reason` is usually null. Whether another field or the log holds it is unchecked.
- **Private log values.** The unified log shows `<private>` for values not logged as public. Whether `log config` in the guest can lift that for a simulator is untried.
- **Flaky scroll check.** The matrix's `swipe scrolls` fails intermittently under load with no fix yet; whether the guest drops part of the drag or the check reads too early is unknown.
