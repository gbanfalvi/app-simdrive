---
name: write-code
description: >-
  Coding, naming and testing conventions for simdrive, and how to land a change. Use before writing or changing
  any Swift, Python or shell code or tests, however small: implementing a command or capability, fixing a bug,
  adding a test, changing the probe app or the evaluation matrix, or carrying out a backlog item.
---

# Write code

## Before typing

- Read `AGENTS.md` ("Adding a capability" for anything new) and the backlog item you're carrying out.
- Look for an existing type, function or utility to reuse, and for the pattern similar code already follows.
  Follow it, or change it everywhere.
- Hunt edge cases now, not after the tests pass: every device family, posture and runtime; a device that just
  booted; a guest that stays silent; concurrent calls through the daemon.

## Code

- **Respect the layers.** `SimDriveNative` speaks in domain terms behind `package` API; `SimDriveCore` never sees
  an XPC object, mangled name or selector. Logic beyond calling a driver goes in a Core type, not in the driver or
  in `DeviceSession`.
- **Prefer deletion.** When improving or refactoring, look for removals before additions.
- **No new singletons.** Inject what a type depends on. Process-wide private-framework state that already exists
  (`ABIRuntime.shared`, `CoreDeviceManager`) is the exception, not the pattern.
- **Be deliberate with access control.** Never loosen it for tests; use `@testable import` or inject fakes.
- **Account for every call site** of anything you change: grep `Sources/`, `Tests/`, `Evaluation/`, the README and
  `skills/simdrive/SKILL.md`.
- **Closures for events only with one guaranteed observer.** Otherwise model the change as a value or a stream.
- **Watch for retain cycles** in XPC handlers and daemon callbacks. Use `[unowned self]` only when ownership
  guarantees the lifetime, and say so in a comment.
- **Concurrency:** async/await, actors for serialized state, `Task` for asynchronous work. Bound every wait on the
  guest with a deadline; a silent guest must fail with a named code, never hang the daemon.
- **Comments only for what the code can't say**, 1–3 lines; an inline one-liner where the "what" isn't obvious.
  Private-API facts and observed device behavior go in `docs/`, with a short pointer in the code when needed.
- **Validate at boundaries**, narrow types there, and keep the inside consistent instead of re-checking.

## Naming

- **Use the domain's and platform's terms:** `posture`, `hinge`, `pasteboard`, `digitizer`, `interface
  orientation`; Apple's names for private symbols stay inside the driver that binds them.
- **Public names don't leak implementation:** `set(_ posture:)`, not `sendHingeAngleOverCoreDevice(_:)`.
- **One name per concept across the codebase, CLI, JSON and docs:** a flag, result field or error code is named
  once and reused everywhere.
- **Commands and error codes are a contract.** Agents branch on `code` strings and JSON fields; renaming one is a
  breaking change to discuss with the user first.

## Tests

- **Each test answers one question: "what are we testing?"** Asserting a dozen unrelated things doesn't answer it,
  and neither does missing the key codepaths.
- **Unit tests cover pure logic** with Swift Testing (`@Suite`, `@Test`, `#expect`/`#require`) and need no
  simulator. Anything that touches a guest is checked by `Evaluation/matrix.py`, which checks effects in the
  probe app, not replies.
- **Tests are isolated and clean up after themselves**: temporary files, sockets, daemons, simulator settings.
- **Prove a new test can fail.** When it guards against drift or a regression, break the code on purpose, run
  `swift test --filter <Suite>`, watch the test fail for the right reason, then undo exactly that edit (not
  `git checkout` of the file, which drops your other changes). If it still passes, it doesn't test what you think.
- **Caches hide first-call bugs.** The daemon and `LazyCapability` cache; assert on the first call, and run the
  matrix against a fresh daemon (`simdrive <udid> stop` first) when the change is on an open path.
- **A fix that breaks other tests isn't done.** Find out why before touching those tests. Change a test's
  expectation only when it asserted something incidental, and say so in the commit.

## Landing a change

- **Build and test:** `swift build` and `swift test` while iterating; `swift build -c release` then
  `Evaluation/matrix.py <udid> --only <sections>` on simulators you created for anything that reaches a guest.
  Stop the daemons you started.
- **Edit with the editor;** keep scripts for multi-file changes.
- **One commit per step,** with a message that says why, and the backlog item's ID in the subject when there is
  one (`Add pinch and rotate (N9)`). In the same commit, update the README's command table and JSON, the skill
  in `skills/simdrive/SKILL.md`, `docs/` and the backlog item when they're affected.
- **Record what you didn't do.** Edge cases left unhandled, extras skipped, devices or runtimes not run: add them
  to the backlog with the `backlog` skill before reporting done.
- **Then run the `review` skill on your own change** before reporting it done. Report what you verified, on which
  devices and runtimes, and what you didn't.
