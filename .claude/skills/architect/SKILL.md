---
name: architect
description: >-
  Design and architecture principles and the planning workflow for simdrive. Use before designing or planning
  anything non-trivial: a new command or capability, a driver for a private framework, module or type boundaries,
  an architecture or design review, choosing between approaches, a change to the daemon or its protocol, or a
  phased/incremental plan. Also use when asked to "review the architecture", "come up with a plan", "how should we
  structure", or when a change touches more than one module.
---

# Architect

Design and review **top-down, at every level**: package → module (`SimDriveNative`, `SimDriveCore`, `simdrive`) →
type → member. Size the work first; you won't always need every level, but working at one level only misses
architectural problems.

## At each level, ask

- **Boundaries.** What belongs here conceptually and what belongs elsewhere? Each module uses only the one below
  it. Private-framework shapes (XPC objects, mangled names, selectors, ABIBridge types) stay in `SimDriveNative`,
  behind `package` API in domain terms; logic beyond calling a driver goes in Core. What should be exposed outside
  this unit, and how are its dependencies supplied?
- **Testability**, at module, instance and function level: focused single-purpose units, injected dependencies,
  separated responsibilities. Pure logic (parsing, geometry, log queries, layouts) lives apart from the code that
  talks to the guest, so `swift test` covers it without a simulator. Between two patterns, choose the more easily
  testable one.
- **Reuse.** Can this be a general-purpose type or function that still has a single responsibility? When
  repetition happens anyway, enforce one consistent pattern ("Adding a capability" in `AGENTS.md` is the one for
  capabilities), and call out or fix deviations now rather than later.
- **Fit, extend, or redesign?** Weigh (a) fitting the change into the existing architecture for consistency,
  (b) a different approach when extending would break single responsibility or overcomplicate things, and
  (c) a substantial redesign of that part. Say which you chose and why.
- **Concurrency.** How will it be used and misused across actors, the daemon's request queue, XPC callbacks and
  concurrent CLI calls against the same device? What does it cost in latency per call?
- **Devices and runtimes.** iPhone, iPad, iPhone Duo (both panels and every posture), Apple TV; the oldest and
  newest supported runtimes; a device that just booted, rebooted or shut down. Where a capability is missing, the
  driver's `open` returns nil and the command fails with a named error code.
- **SOLID, both ways.** Watch for under-use (god objects, mixed responsibilities, tight coupling, unclear
  boundaries) and over-use (over-modularizing, needless protocols, too much indirection, abstractions with a
  single implementation).
- **Boundaries validate.** Parsing, validation, type narrowing and error codes go at unit boundaries
  (`CommandParser`, driver `open`). Internally the design should be consistent enough not to need re-checking;
  outside input (arguments, guest replies, private-framework results) gives no such guarantee.

## Principles

- **DRY the structure, not every line.** Three similar statements beat a premature abstraction. Prefer explicit
  over clever or excessive indirection.
- **Simple over easy.** An intermediate type can make one call site easier while making the whole harder to
  follow. Add an abstraction only when it pulls its weight in the design.
- **Keep parallel implementations apart.** A second transport for the same capability (guest Mach service vs
  CoreDevice, old vs new runtime) is separated as far down as possible, so consumers don't see the details and
  removal is one deletion.
- **Flat call hierarchy.** If answering a question means tracing more than ~5 files or layers, it's too deep.
  A rich interface hiding substantial work is fine; a deep chain of thin layers is not.
- **Check the codepath.** Before threading a new signal through several layers (CLI → daemon → session → driver),
  ask whether that's the right path, whether each layer is used properly, and whether it adds needless
  abstraction.
- **Consolidate decisions.** Make each choice in one place and pass the result on as a simple value.
- **Minimize state.** Prefer pure functions to mutation, locals to properties, properties to session state, and
  session state to globals. **Derive instead of syncing.** The daemon outlives calls, so anything it caches must
  be safe across a reboot, a rebuild and a guest that stops answering.
- **Model all the things.** Scattered booleans, repeated shape assumptions and branching spread across files are
  accidental complexity; put them in a model (value types, enums, catalogs like `SettingCatalog`).

## Process

1. **Read the real code** at every level you'll touch, including callers, the daemon path and the matrix. Read
   `docs/architecture.md`, `docs/design-decisions.md` (including the alternatives that failed) and
   `docs/private-apis.md` before proposing a transport. Delegate wide searches; read critical files yourself.
2. **Hunt edge cases up front.** Assume the developer and the docs missed them. `docs/device-behavior.md` and
   `docs/open-questions.md` list what the guest has already done to us.
3. **Consider alternatives** wherever there's ambiguity. If the trade-off is unclear, spike it against a
   simulator you created (and delete the spike afterwards) instead of guessing. Mark what you didn't run as
   unverified.
4. **Decide or ask.** Verify what's verifiable yourself. For consequential choices that shape later work (a new
   private dependency, a change to the JSON contract or the error codes agents branch on), give the user the
   options with pros and cons and a recommendation. Push back on requests that don't make sense.
5. **Size from the code, not the estimate.** Before ordering work, trace each item's plumbing. Backlog costs are
   guesses; when tracing changes one, or shows an item should wait for another, update the item with why.
6. **Measure before optimizing.** A speed change starts with a baseline: `Evaluation/matrix.py <udid> --timing
   --label <name>` on the old build, then the new, in several rounds (`tree` timings are bimodal).
7. **Plan in increments.** Big changes are fine if every step builds, passes `swift test`, and is one commit.
   Order steps so earlier ones unblock later ones; put deletions and guard rails first.
8. **Write the plan down** in the backlog item it carries out (`roadmap/backlog.md`): Problem or Why, Read, Do,
   Test, in that file's style. A plan with no item gets one first (`backlog` skill). Record results under a
   **Result:** line as steps land, and move what was learned into `docs/`.
9. **Backlog what's deferred.** Alternatives set aside, milestones past this plan, steps cut and edge cases
   accepted rather than handled go into `roadmap/backlog.md` (`backlog` skill).

Settled decisions and their reasons live in `docs/design-decisions.md`; respect them or say explicitly why one
should change, and update it when one does.
