---
name: review
description: >-
  How to review code, designs and plans in simdrive, and how to report findings. Use when asked to review a diff,
  branch, PR, module, file, backlog item or plan ("review this", "look over", "what's wrong with", "audit"), and
  to self-review your own changes before telling the user work is done.
---

# Review

## Process

1. **Read the code, not a summary of it.** For a diff, also read the surrounding code, the callers and the path
   a request takes (CLI → daemon → session → driver). Delegating wide searches is fine; judge the critical files
   yourself.
2. **Review at every level that's affected:** package, module, type, member. Problems found only in a diff often
   start one level up.
3. **Hunt edge cases.** Assume they were missed: iPhone, iPad, Duo in every posture and both panels, Apple TV;
   the oldest and newest runtimes; rotation; the first call after boot or reboot; a guest that never answers;
   concurrent calls on one device; a stale daemon from an older build; empty or malformed input.
4. **Verify claims by running them.** `swift test --filter <Suite>`, a temporary probe test you delete
   afterwards, or `Evaluation/matrix.py <udid> --only <sections>` on a simulator you created; `--timing` for speed
   claims. A finding you couldn't reproduce is labeled as unverified.
5. **Check the tests:** does each one answer "what are we testing?", are the key codepaths covered, and would the
   test actually fail if the code broke? Is guest behavior covered by the matrix rather than asserted on replies?

## What to check against

- The design principles in `.claude/skills/architect/SKILL.md`: boundaries, testability, reuse, fit vs extend vs
  redesign, simple vs easy, SOLID both ways, concurrency, flat call hierarchy, state, modeling.
- The code, naming and test rules in `.claude/skills/write-code/SKILL.md`.
- `AGENTS.md`: the module layering, "Adding a capability" (every step, including README and skill), and the
  Working agreements, in particular root causes rather than symptoms, and mechanisms rather than reminders.
- `docs/design-decisions.md`: settled choices and the alternatives that already failed.
- The contract: command syntax, JSON fields and error codes agents rely on, and the README and skill describing
  them accurately.

## Report

- **Findings come first, ranked by severity.** Each has a `file:line` reference, a concrete failure scenario
  (device, inputs or state → wrong result), why it matters and a suggested fix.
- **Nits** go in a separate short list.
- **Findings not fixed in this work go into the backlog** (`backlog` skill), labeled unverified where you couldn't
  reproduce them, so they outlive the report.
- **Be honest about the input.** If the request or design itself has a problem, say so.
- **Self-review before reporting done:** run this on your own change. Report what passed, what you ran (and on
  which devices and runtimes), and what you couldn't verify.
