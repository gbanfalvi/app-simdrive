# AGENTS.md — simdrive

simdrive drives booted iOS and tvOS simulators from the command line for agents. See [README.md](README.md) for what it does.

## Install the skill

The agent skill in [skills/simdrive/SKILL.md](skills/simdrive/SKILL.md) teaches an agent to use simdrive. To install it:

1. Build: `swift build -c release` in this clone.
2. Copy `skills/simdrive/` into your skills directory: `~/.cursor/skills/` for Cursor, `~/.claude/skills/` for Claude Code, or your agent's own.
3. In the copy, replace `<simdrive>` with the absolute path of `.build/release/simdrive` in this clone.

Reinstall after changing the skill here; the repo copy is the source.

## Working on simdrive

- Builds need Xcode 27 and macOS 26. Set `DEVELOPER_DIR` to the Xcode in use, such as `/Applications/Xcode_27_2.app/Contents/Developer`, when `xcode-select` points elsewhere.
- Build with `swift build`, test with `swift test`, and release with `swift build -c release`.
- Modules, lowest first. Each uses only the one below:
  - `SimDriveNative`: private-framework drivers for CoreSimulator, the guest's HID and device-control services, CoreDevice, and AccessibilityPlatformTranslation. `Guest*` types reach the guest's Mach services directly; `CoreDevice*` types go through CoreDevice.
  - `SimDriveCore`: commands and their parser, the per-device session, screen geometry, and the per-device daemon.
  - `simdrive`: the executable, which calls `SimDriveCLI.run`.

### Adding a capability

1. Driver in `SimDriveNative`: a type with `static func open(...) async throws -> Self?`, returning nil when the device lacks it, and methods in domain terms.
2. Session method in `Sources/SimDriveCore/Session/DeviceSession.swift`, opening the driver lazily through `LazyCapability`.
3. A `Command` case, its parsing in `CommandParser`, and a line in the usage text.
4. Error codes as `ErrorCode` constants.
5. Parser tests, plus tests for any pure logic.
6. The README's command table and JSON results, and the skill.

A device setting is one row in `Sources/SimDriveCore/Settings/SettingCatalog.swift`, with no new command. Find its key by diffing `simctl spawn <udid> defaults export <domain> -` before and after toggling it in Settings, and its notification among the strings of UIKit and libAccessibility, with its `cache.` counterpart. Keep the row only if a probe app sees the change while running on the oldest and newest iOS runtimes, set `minimumOSVersion` where it is newer, and add it to the README's settings table.

### Verifying

- Check behavior end to end on a simulator with a probe app that logs the events it receives; a command that returns `ok` may still have been dropped by the guest.
- Use simulators you created; leave the user's other simulators, and their state, alone.
- Never write the Mac clipboard, and only write a simulator's pasteboard with the user's consent: a syncing host such as DeviceHub copies it to the Mac clipboard.
- Stop the daemons you started: `simdrive <udid> stop`.
