---
name: refactor
description: >-
  How to restructure simdrive code safely. Use before renaming, moving, splitting, merging, deleting or
  deduplicating code, extracting or inlining types, moving logic between SimDriveNative and SimDriveCore,
  replacing one transport or mechanism with another, or carrying out a refactor step from a backlog item — any
  change meant to keep behavior the same.
---

# Refactor

1. **Know why.** Name the problem being removed: a mixed responsibility, duplication, a leaky boundary (a private
   framework's shape reaching Core), needless state. If the cause is a symptom of something deeper, fix the deeper
   thing. When the shape of the change is unclear, use the `architect` skill first.
2. **Prefer deletion.** Look for what can go before adding anything: dead code, a workaround the new design makes
   unnecessary, a parallel path, a fallback for a runtime no longer supported.
3. **Pin behavior first.** Existing tests must cover what you're changing: `swift test` for pure logic, the
   matrix's sections for anything that reaches a guest. If they don't, add characterization tests before touching
   the code, and prove they can fail.
4. **Small steps, each green.** Every step builds, passes `swift test`, and is its own commit. When a step touches
   a driver or the daemon, run the affected matrix sections on a simulator you created. Big refactors are fine
   done progressively.
5. **Find every call site first.** Grep `Sources/`, `Tests/`, `Evaluation/`, `docs/`, the README and
   `skills/simdrive/SKILL.md`. Renames are text, not semantics: build, test and read the diff afterwards,
   including comments and docs.
6. **Keep the contract.** Command syntax, JSON fields and error codes don't change in a refactor. If one must,
   it's a behavior change: stop and ask.
7. **Keep old and new apart.** If both must live side by side for a while, separate them as far down as possible
   so the old one goes in a single deletion. Don't interweave them.
8. **Fix the environment.** If the old shape could come back, add a mechanism against it: a test, a `package`
   boundary, a type that makes misuse fail to compile.
9. **Update the record** in the same commit: `docs/architecture.md` (modules and source layout),
   `docs/design-decisions.md`, `AGENTS.md`, and the backlog item. Duplication, smells or bugs you noticed but left
   alone go into the backlog (`backlog` skill).
10. **Finish with the `review` skill** on the whole refactor.
