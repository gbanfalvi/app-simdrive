---
name: backlog
description: >-
  How to record work that could be done but isn't done now, in roadmap/backlog.md, and to move an item to
  roadmap/completed.md when it lands. Use whenever work turns up
  something left undone — a possible bug or device quirk, a possible performance regression or optimization, a
  missing test or matrix check, a missing command or option, a cleanup, a review finding or nit not fixed, a step
  cut from a plan, something not verified on a device or runtime — and when an item lands. Also use when asked to
  add to, reorder or tidy the backlog.
---

# Backlog

`roadmap/backlog.md` is the one list of open work; `roadmap/completed.md` holds the items that landed, under the
same sections and IDs. Anything that could be done but isn't done as part of the current work goes into the
backlog, **before the work is reported done**. A finding that lives only in a chat message, a
commit message or a doc's prose is lost. Follow the file's own Conventions section; this skill adds when and how.

## What counts

Record it if it's real work someone might do, whatever the reason it was left: out of scope, too big, needs a
decision, blocked, not worth it yet, or noticed in passing.

- **Correctness:** a suspected bug, an unhandled device or runtime, a review finding not fixed (with "unverified"
  if you didn't reproduce it).
- **Performance:** a suspected regression, a measured slow command, an optimization tried and deferred.
- **Features and extras:** a command, option, button, gesture or setting left out; a follow-up milestone.
- **Quality and tooling:** duplication, a missing unit test or matrix check, a probe app gap, a script worth
  adding.
- **Verification gaps:** anything only built or unit-tested that needs the matrix, another device family or
  another runtime.

Don't record what you're about to do in the same task, one-line typos you can just fix, or speculation with no
concrete change behind it. Fixing it now beats recording it when it's small and in scope.

## Adding an item

1. **Check for an existing item** (search IDs and keywords in both files). Extend an open one rather than adding a
   duplicate: a new observation goes in as a **Seen (date, where):** bullet. Something a completed item left or
   broke becomes a new open item that names it.
2. **Pick its section by kind:** `1. Fixes` (`F`) for wrong or missing behavior of what exists, `2. Improvements to
   existing commands` (`I`) for speed, reliability, output and tooling around existing commands, `3. New features`
   (`N`) for new commands and capabilities. Within a section, place it by cost, after any item it needs.
3. **Give it the next free number** in that prefix, after the highest in either file. IDs are never reused.
4. **Write the heading** as the others are: `### - [ ] F19. <short title> (<cost>[, unverified | needs N15 | cause
   unknown])`, cost S, M or L as the Conventions define them.
5. **Write the body** concrete enough to start from without this conversation: **Problem:** (fixes) or **Why:**,
   then **Read:** with `S:` paths and symbols, **Do:**, and **Test:** naming the unit tests or matrix sections
   that prove it. Mark claims nobody ran in simdrive as unverified.
6. **Put long detail where it belongs:** measurements and device behavior in `docs/`, linked from the item.
7. **Commit it** with the work that found it, or on its own if that work isn't committed.
8. **Tell the user** in the report which items you added or extended, by ID.

## When an item lands

In the commit that lands it: tick it (`- [x]`), add a **Result:** line under the heading with what was measured or
decided, and move the whole item from `roadmap/backlog.md` to the end of the same section in
`roadmap/completed.md`. Move what was learned into `docs/`, and recheck open items that said "needs" it. Whatever it
left undone gets its own open item in the backlog, named in the Result ("Left: I28"). An item only partly done
stays in the backlog with a **Result so far:** line until it lands.
