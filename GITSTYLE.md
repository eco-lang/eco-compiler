# Commit Message Style Guide

Conventions distilled from this repository's history. Follow them for every commit.

## Subject line

- **One imperative-mood verb, capitalized, no trailing period.**
  Write the subject as a command that completes the sentence "This commit will…":
  *Add*, *Fix*, *Remove*, *Document*, *Update*, *Move*, *Make*, *Implement*, *Use*,
  *Split*, *Replace*, *Drop*, *Rewrite*, *Route*, *Refactor*, *Guard*, *Repair*.
- **Keep it to ~50–70 characters** (median in this repo is 56). Be specific, not generic:
  prefer "Read the clock when Time.now's task runs, not at module init" over "Fix timer bug".
- **No scope prefixes, tags, or ticket numbers** (`compiler:`, `[fix]`, `#123`). Just prose.
- Name the concrete thing changed — module, target, file, or behavior — using the codebase's
  own vocabulary (`MonoDirect`, `EXCLUDE_FROM_ALL`, `Cheney scan loop`, `heap-profile.py`).

### Good subjects

```
Allow the release bundle version to be passed in as an argument
Read the clock when Time.now's task runs, not at module init
Remove unused variables to silence compile warnings
Split GC stats into minor and major and roll them up at exit
```

## Body

- **Separate from the subject by one blank line.** Short, self-evident changes may be
  subject-only (e.g. "Correct the preset name in the Readme docker example").
- **Hard-wrap body lines at 100 columns.**
- **Write in the present tense, describing what the change does and why** — not what you did.
  "Drive the musl bundle version from version.txt as the baseline, overridable via…",
  "Guard two stats-only references so the -DENABLE_GC_STATS=0 build compiles."
- **One paragraph per logical change.** If a commit touches several distinct concerns,
  give each its own paragraph separated by a blank line. Lead each paragraph with the change,
  then the mechanism and the rationale.
- **Explain the why, especially the non-obvious.** State the problem a fix solves, the
  constraint that forced an approach, or the consequence avoided ("…dragged them through the
  link when building `--target package`"). Future readers have the diff; they need the reason.
- Reference symbols, files, flags, and targets inline using their exact names so the message
  is greppable and unambiguous.

### Example

```
Repair static (ENABLE_GC_STATS=0) build and bundle packaging

Guard two stats-only references so the -DENABLE_GC_STATS=0 build compiles. The TLH alloc
trampolines in GCStats.cpp no longer call getStats() (which does not exist without stats), and
the [gc-profile] fprintf reads a guarded major_gc_seq instead of stats_.major_gc_count.

Fix the CPack failure where install(PROGRAMS ${ECO_BUNDLED_LD_LLD}) saw -NOTFOUND. The
no-static-lld fallback now writes the build lld into the cache with FORCE, so the top-level
install scope sees the value instead of the stale find_program result.
```

## Quick checklist

- [ ] Subject is an imperative phrase, capitalized, no period, ≲70 chars.
- [ ] Subject names the specific thing changed, not a vague category.
- [ ] Blank line between subject and body (when a body is present).
- [ ] Body wrapped at 100 columns, present tense.
- [ ] Each distinct concern is its own paragraph.
- [ ] The *why* is stated wherever it isn't obvious from the diff.
