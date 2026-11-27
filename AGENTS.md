# AGENTS.md — simdrive

simdrive drives booted iOS and tvOS simulators, and paired physical devices on iOS and tvOS 27, from the command line for agents. See [README.md](README.md) for what it does, and [architecture](docs/architecture.md#simulators-and-physical-devices) for how the two kinds share code.

## Install the skill

The agent skill in [skills/simdrive/SKILL.md](skills/simdrive/SKILL.md) teaches an agent to use simdrive. To install it:

1. Build: `swift build -c release` in this clone.
2. Copy `skills/simdrive/` into your skills directory: `~/.cursor/skills/` for Cursor, `~/.claude/skills/` for Claude Code, or your agent's own.
3. In the copy, replace `<simdrive>` with the absolute path of `.build/release/simdrive` in this clone.

Reinstall after changing the skill here; the repo copy is the source. Other repos keep their own copies: app_mono's `scripts/simdrive --sync-skill` recopies it there.

## Skills for working on simdrive

`skills/simdrive/` is the skill simdrive ships to its users. The skills for changing simdrive itself live in `.claude/skills/`; `.cursor/skills/` links to them. Invoke the matching one before starting each activity, and again when the work shifts to another one. They hold the detailed principles and checklists; this file only holds what applies all the time.

| Skill | Invoke before… |
|---|---|
| `architect` | designing or planning anything non-trivial: a command or capability, a driver, module boundaries, daemon changes, architecture reviews, phased plans |
| `write-code` | writing or changing code or tests, however small, including the matrix and the probe app |
| `review` | reviewing a diff, PR, module or plan, and self-reviewing before telling the user work is done |
| `refactor` | restructuring, renaming, moving, deleting or deduplicating code without changing behavior |
| `backlog` | recording work left undone (findings, extras, deferred fixes, unverified devices or runtimes), and moving an item to `roadmap/completed.md` when it lands |

They chain: a design ends in a backlog item's plan that `write-code` carries out, every implementation or refactor ends with a `review` pass, and whatever any of them leaves undone ends in the backlog. If a skill can't be invoked (in a subagent, or a session started before the skill existed), read `.claude/skills/<name>/SKILL.md` and follow it. `.claude/hooks/skill-reminder` repeats this table in one line on every Claude Code prompt.

To drive a simulator while working here, follow `skills/simdrive/SKILL.md` with `<simdrive>` read as `.build/release/simdrive`.

## Working agreements

- **Size the work first.** Its complexity decides how many levels (package, module, type, member) you work at.
- **Hunt edge cases up front.** Assume they were missed and the docs skipped them; raise or handle each one. Devices, postures, runtimes and boot timing are where simdrive's bugs have come from.
- **Fix root causes, never symptoms.** Trace every problem to its source; a retry or a longer sleep hides one.
- **Decide consequential things with the user.** Verify what can be verified first, then give options with pros and cons. Don't guess on decisions that shape later work, such as a new private dependency or a change to commands, JSON or error codes.
- **Push back.** If a request has problems, say so and explain why before doing it.
- **Leave it better (scout's rule).** No placeholders, TODOs or compromises that limit scalability.
- **Nothing found gets lost.** Anything that could be done but isn't done in this work (a possible bug, a device not checked, a review finding not fixed, a feature extra, a cut step) goes into `roadmap/backlog.md` before reporting done, following the `backlog` skill. Say which items you added.
- **Fix the environment, not just the instance.** Turn recurring fixes into mechanisms (tests, matrix checks, scripts) rather than written reminders. Automate repeated work.
- **Verify against the real thing.** Run it on a simulator, test it, measure it; say plainly what wasn't verified, and on which devices and runtimes it was.
- **Communicate concisely**, with the context needed to decide.

## Working on simdrive

- Builds need Xcode 27 and macOS 26. Set `DEVELOPER_DIR` to the Xcode in use, such as `/Applications/Xcode_27_2.app/Contents/Developer`, when `xcode-select` points elsewhere.
- Build with `swift build`, test with `swift test`, and release with `swift build -c release`.
- Planned work, with context for each item, is in [roadmap/backlog.md](roadmap/backlog.md); landed items, with their results, move to [roadmap/completed.md](roadmap/completed.md). What the code doesn't say (architecture, design decisions and the alternatives that failed, private APIs, device behavior) is in [docs/](docs/README.md); read the relevant page before changing that area, and update it in the same commit.
- `swift build`, `swift test` and read-only git commands are pre-approved in `.claude/settings.json`.
- Modules, lowest first. Each uses only the one below:
  - `SimDriveNative`: private-framework drivers for CoreSimulator, the guest's HID and device-control services, CoreDevice, and AccessibilityPlatformTranslation. `Guest*` types reach the guest's Mach services directly; `CoreDevice*` types go through CoreDevice.
  - `SimDriveCore`: commands and their parser, the per-device session, screen geometry, device logs, and the per-device daemon.
  - `simdrive`: the executable, which calls `SimDriveCLI.run`.

### Adding a capability

1. Driver in `SimDriveNative`, in the folder of its kind (`Input/`, `DeviceControl/`, `Accessibility/`): a type with `static func open(...) async throws -> Self?`, returning nil when the device lacks it, and methods in domain terms.
2. Session method in `Sources/SimDriveCore/Session/DeviceSession.swift`, opening the driver lazily through `LazyCapability`. Logic beyond calling the driver goes in a type in the Core folder of the same name, as `Screens/` and `Accessibility/` do.
3. A `Command` case, its parsing in `CommandParser`, and a line in the usage text.
4. Its JSON in `Sources/SimDriveCore/Commands/CommandResults.swift`, and error codes as `ErrorCode` constants.
5. Parser tests, plus tests for any pure logic.
6. The README's command table and JSON results, and the skill.

A device setting is one row in `Sources/SimDriveCore/Settings/SettingCatalog.swift`, with no new command. Find its key by diffing `simctl spawn <udid> defaults export <domain> -` before and after toggling it in Settings, and its notification among the strings of UIKit and libAccessibility, with its `cache.` counterpart. Keep the row only if a probe app sees the change while running on the oldest and newest iOS runtimes, set `minimumOSVersion` where it is newer, and add it to the README's settings table.

### Verifying

- Check behavior end to end with `Evaluation/matrix.py <udid>` after `swift build -c release`; a command that returns `ok` may still have been dropped by the guest. On iPhones it installs the probe app in `Evaluation/Probe`, which logs the events it receives. `--only tree,tap` runs some sections, and `--timing --label <name>` times common commands into `.build/evaluation`; `SIMDRIVE=<path>` compares another build.
- Use simulators you created; leave the user's other simulators, and their state, alone. `Evaluation/fresh.py` creates one, runs the matrix on it cold, and deletes it if every check passes. Keep a simulator that failed until you know why.
- After splitting work into several commits, `scripts/check-commits` builds and tests each unpushed one on its own.
- Never write the Mac clipboard, and only write a simulator's pasteboard with the user's consent: a syncing host such as DeviceHub copies it to the Mac clipboard.
- Stop the daemons you started: `simdrive <udid> stop`.
- A physical device is someone's own: drive it only as far as they agreed, never read or write its pasteboard, change its settings only to put them back, and leave it as you found it. `Evaluation/matrix.py <device-udid>` runs device mode, which puts back what it changes; an iPhone's needs `SIMDRIVE_TEAM` set to the team that signs the probe.
