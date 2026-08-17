# LSS Opt Track — Solver+LSS Cold-Cache Benchmarks

Tracks the wall/GC impact of the LSS substrate and analysis track
(`plans/lss-set-write-substrate.md`;
`design_docs/auto-borrow-inference/lss-paper-fidelity-mapping.md` and successors —
making lambda-set solving cheaper per fact, then making it know more facts) on the
standard bootstrap workload. Append one labelled section per run.

**This track measures the SOLVER, not the subst pipeline.** The whole point of the
LSS work is the cost and precision of solver+LSS monomorphization, so both the tested
binary AND the measured workload run `ECO_MONO_ENGINE=solver ECO_MONO_LSS=1`. That is
the difference from `benchmarks/kernel-opt.md`, whose workload is deliberately
subst-mode so the *job* stays constant while the binary changes — the opposite of what
this track needs.

---

## Recording instructions (fixed — keep every entry uniform)

**Entry shape (fixed, and it is a hard rule): the results table(s) FIRST, then AT MOST
10 LINES of prose. Nothing else** — no preamble above the table, no appendices below the
prose, no sub-headings inside an entry. If the analysis does not fit in 10 lines it
belongs in the plan file, not here.

**Per run:** give it a **label** (Run A, Run B, …). Record **wall time**, **max RSS**,
`Minor GC cycles`, `Major GC cycles`, `Objects promoted` (count and MB), `Total GC/Alloc
time`, and the output `.mlir` byte size (workload-constancy check). Never report a wall
without its majors — trigger-lottery lesson. Also record the `lss census` counters when
the change touches them (`ECO_MONO_LSS_REPORT=1`): `set-writes`, `joins`, `widened`,
`setsZonked`, `join flush: rounds/retranslations`.

**Heap allocation counts are NOT tracked in this file.** HEAP_034's inline-alloc fast
path bypasses the per-tag counter, so `Objects allocated` / `Bytes allocated` undercount
codegen'd constructs (~6× on this workload) and mislead by default. **`Minor GC cycles`
is the honest allocation-pressure proxy** — every minor cycle is a real nursery fill, and
it is counted by the collector, not by the blind instrumentation. Record `Objects
allocated` only in a purpose-built census leg with an `ECO_INLINE_ALLOC=0`-lowered
binary, and label it explicitly as such inside the run entry.

**What this protocol is and is not (read before drawing a conclusion).**
It is a **regression check**, not a precision instrument. Solver+LSS runs are long
(minutes, not seconds) and this protocol deliberately buys ONE sample per side, so:

- a delta of **≳3%** on wall is a real signal — report it;
- anything **below that is FLAT**. Write "no regression detected", never "a −1% gain".
  A sub-noise number is not a measurement.
- **The GC counters are exact even from one run.** `Minor/Major GC cycles` and `Objects
  promoted` are deterministic per (binary × tree) — they carry real information at n=1,
  and an unexpected move in *those* is a far stronger signal than a few seconds of wall.
  **Judge changes on the counters first, wall second.**
- Establishing a genuine small (<3%) gain is a deliberate, separately-budgeted exercise,
  not part of the routine protocol. Do not drift into it by adding runs until the number
  looks good.

**Two kinds of run — and most runs in this track are the FIRST kind.**

- **Plain run (the default; use it for any unflagged code optimization).** Most LSS
  substrate work is *unconditional* — a representation swap, a write-protocol change, a
  memo: there is no flag to toggle and therefore no "off" arm to measure. Do **ONE cold
  run**, record its numbers as a single row, and compare against the PREVIOUS run's row
  in the summary table. No arms, no `on`/`off` labelling, no second binary — just the
  numbers. The run entry says what changed since the row above it and what the counters
  did.
- **A/B run (only when a real toggle exists).** When the change is genuinely behind a
  flag, or a suspected regression is worth isolating against a pre-change binary, use two
  arms labelled `on`/`off` (flag) or `post`/`pre` (two binaries, two trees), **one cold
  run each**.

**No second round and no warmup leg, in either kind.** Solver+LSS legs are long enough
that a second round costs more than the information it buys for a regression check; a
regression big enough to matter here is obvious at n=1, and the GC counters are exact
anyway. There is no `r1`/`r2` suffix and no round-reversal step.

**Summary table:** maintained at the **bottom of this file** — one row per run:
`Run | Wall (s) | Num Minor GCs | Num Major GCs | Promoted objects (MB)`. Numbers are
for the arm **with the run's optimization applied**. **The table contains NUMBERS ONLY —
no commentary, no verdicts, no bold, no footnotes, no parenthetical caveats, no "—
FLAT", nothing but the run label and its four figures.** Every caveat, secondary figure,
census delta and interpretation belongs in the run entry. Wall is in seconds (e.g.
`241.6`, not `4:01.6`) so the column is directly comparable and sortable.

**READING THE SUMMARY TABLE DOWN A COLUMN — the discipline is mandatory here.** The wall
column is comparable ACROSS ROWS only while the workload is unchanged, and the workload
is **the compiler's own source** — so any item that adds compiler source enlarges it and
shifts the absolute wall for every later run. In the kernel-opt track that made cross-row
reading a trap to avoid; here, because **plain single runs are the norm**, cross-row
comparison IS the primary mechanism, so the guard rails are not optional:

- every run entry MUST record the `out.mlir` byte size;
- any cross-row wall claim MUST quote both rows' `out.mlir` sizes;
- if they differ materially, the corpus moved and the wall delta is NOT attributable to
  the change — say that, instead of reporting a regression or a win.

`out.mlir` is deliberately not a summary column; it lives in the entries, which is where
the comparison argument has to be made anyway.

**Solver+LSS-specific comparability warning.** Because the measured workload now runs
the solver, a change to the LSS analysis moves BOTH the binary and the job it does.
Two consequences: (a) `out.mlir` byte-identity across arms is the check that the change
was substrate-only (a substrate optimization must not move it; an analysis change
deliberately will — say so); (b) a wall change may be the analysis doing more work
rather than the binary running slower. Attribute explicitly, using the lss census
counters, before calling anything a regression.

---

## Methodology (repeat exactly each time)

**Workload — cold-cache Stage 7a under solver+LSS.** The tested `eco-compiler` binary
compiling the entire compiler front-end (`compiler/src/Terminal/Main.elm`, ~243 modules)
to MLIR, with the workload run under **`ECO_MONO_ENGINE=solver ECO_MONO_LSS=1`**. This
is the configuration the LSS track exists to improve, so it is the configuration
measured: the numbers include the recursive cost of lambda-set solving as workload.
Expect walls several times the subst-mode figures in `benchmarks/kernel-opt.md` — the
two files' walls are NOT comparable.

**Binary — the thing being tested.** Built with **solver + LSS + borrow ON plus every
track change under test**. `build` preset (RelWithDebInfo, asserts + GC-stats ON — the
standard bootstrap config; ~2.6× slower than release but deterministic). Note:
`ECO_BORROW=1` without report/reify is inert-by-construction today (the Phase-6 pass
self-skips); it is set anyway so the build line already carries every track knob as they
become real.

**Two independent engine knobs** (do not confuse): the **build engine** (env at the
`cmake --build` step — how the binary itself is compiled) vs the **workload engine**
(env at the `make` run — how the binary monomorphizes what it compiles). In THIS file:
build = solver+LSS+borrow+track-changes; workload = **solver+LSS, always**.

**Cache reset — delete `eco-stuff/` immediately before every run; do NOT touch
sources.** `rm -rf build/compiler/build-kernel/eco-stuff` is the honest cold-cache reset
(touching mtimes is fragile; engine changes are invisible to mtime). **Never delete
`~/.eco`** (warm package cache).

**Testing is a separate pass** — never mix gate runs into a benchmark; they pollute
timings and the `eco-stuff/` cache.

**Commands** (run from `/work`):

```bash
BK=build/compiler/build-kernel

# Phase 1 — build the tested binary (repeat when the track changes):
# NINJA IS ENV-BLIND: with no source change, an env-only flavor change does
# NOT rerun Stage 5 — delete its outputs to force it.
rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"
rm -rf "$BK/eco-stuff"
ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1 \
    cmake --build build --target eco-compiler          # + further track env vars as they land
cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-lss-post"
# For an unconditional (flagless) change, build the PRE binary the same way from
# the pre-change tree and keep it as "$BK/bin/eco-lss-pre" — two binaries, one
# frozen corpus, since flag-off is not available.

# Phase 2 — benchmark. ONE cold run per arm. NO second round, NO warmup leg:
# solver+LSS legs are long, and a regression worth acting on is visible at n=1
# (see "What this protocol is and is not" above). Do NOT add rounds.
#   PLAIN RUN (the default for unflagged code optimization): ARMS is ONE name.
#   A/B RUN (only when a real toggle exists): ARMS is two names.
ARMS="eco-lss-post"                    # A/B example: "eco-lss-post eco-lss-pre"
for ARM in $ARMS; do
  rm -rf "$BK/eco-stuff"
  ( cd "$BK" && ulimit -c 0 && \
      ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_MONO_LSS_REPORT=1 \
      /usr/bin/time -v -o "$ARM.time" \
      "./bin/$ARM" make --optimize --kernel-package eco/compiler \
          --local-package eco/kernel=/work/eco-kernel-cpp \
          --output="bin/$ARM-out.mlir" /work/compiler/src/Terminal/Main.elm \
          > "$ARM.stdout" 2> "$ARM.stderr" )
done
# Wall + Max RSS from the .time files; minor/major GC cycles, promoted objects
# and GC time from the GC dump in .stdout; lss census from .stderr; output size
# from the -out.mlir files.
```

For an A/B, `cmp` the `-out.mlir` files. A **substrate** change (representation, write
protocol, state threading, key memoization) must keep them **byte-identical** — that is
the gate proving it was cost-only. An **analysis** change (more precision, more licensed
sites) legitimately moves them; when it does, say so explicitly in the entry and state
what moved, because the wall comparison then includes a workload change.

---

## Runs

### 2026-08-17 — Run A: track baseline (plain run; no change under test)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| base | **5:26.25** (326.3 s) | 6,564,492 kB | 1,348 | 14 | 445,312,948 (12,801 MiB) | 127.44 s | 13,715,426 B |

| axis | value |
|---|---|
| minor / major GC time | 83.84 s / 43.58 s |
| copied-in-nursery | 1,073,450,643 |
| binary | 66,489,560 B |
| set-size histogram | 1→99,142 2→2,799 3→1,787 4→880 5→436 6→310 7→312 8→149 |
| widened | bySize=462 byKernel=4,104 byBudget=50,753 |
| signatures | 9,581 memoized (9,581 trivial) |
| join flush | rounds=3 retranslations=1,010 |
| dispatch | devirtDirect=5,914 devirtKernel=832 dispatchUpgraded=3,163 |
| topSiteShapes | global=14,151 local=7,361 kernel=3,785 other=225 |

Reference point for `plans/lss-set-write-substrate.md`; nothing under test. Tree = this
session's landed work (BitSet oracle, sum merge, cardinality Tiers 1–3). GC dominates:
**127.44 s of 326.3 s wall is GC/alloc (39.1%)**, 1,348 minors, 14 majors — the substrate
plan's target. Concrete sets are 94.2% singletons (99,142 of 105,215 zonked) and only 149
reach the cap of 8, so Phase 2's sorted lists operate almost entirely on 1–2 elements.
`bySize=462` widened sets have no recorded magnitude — precisely what Phase 1's
`widenedSizeHist` adds; `byBudget=50,753` still dominates widening 12:1 over kernels. All
9,581 signatures trivial, confirming the empty-signature-channel finding (GAP-2) here.
Phase-1 counters do not exist yet, so set-write and join populations are unmeasured. Not
comparable with `benchmarks/kernel-opt.md` walls (that workload is subst, this is solver).

### 2026-08-17 — Run B: substrate Phase 1 instrumentation (plain run; counters only)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| p1 | **5:26.78** (326.8 s) | 6,640,604 kB | 1,379 | 13 | 454,314,073 (13,056 MiB) | 123.89 s | 13,724,267 B |

| new census line | value |
|---|---|
| set-writes | skip=62 flex=144,158 **slow=61,403** |
| joins | identical=80,869 noop=4,566 changed=3,425 completion=33,541 |
| widened sizes | 9→115 10→26 11→39 12→18 13→13 14→39 15→14 16→13 17→25 19→6 21→12 22→12 23→1 24→1 25→12 26→24 28→18 30→12 35→13 36→6 48→1 **81→18 97→24** |

Identity gate: the pre-Phase-1 binary and this one produce **byte-identical** MLIR on this
tree — stats-only confirmed. vs Run A: wall +0.5 s (FLAT), minors 1348→1379 (+2.3%),
promoted +255 MiB (+2.0%), majors 14→13. Two causes push the same way and one run cannot
separate them: `out.mlir` grew 13,715,426→13,724,267 B (+8,841 B — the counter code is IN
the corpus) and the join counters add one S copy on the D2 "return S unaltered" path.
**Two plan assumptions are refuted.** The E9.3 skip fires **62 times of 205,623 writes
(0.03%)**, not the "~90%" claimed at `Store.elm:755-758` — that comment is wrong by three
orders of magnitude. And `setWriteSlow` is **61,403 (29.9%)**, not ≈0: the slow path is the
second-largest population, so Phase 2's direct join is worth far more than planned, and its
"delete the defensive arm when the counter reads 0" step is void as written. Sets DO reach
81–97 members in store (42 of the 462 widened), so the write-time ⊤-collapse is warranted.

### 2026-08-17 — Run C: substrate Phase 2 — LsTop|LsMembers sorted-list sets + direct joins (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| p2 | **5:19.74** (319.7 s) | 6,540,428 kB | 1,375 | 12 | 450,045,996 (12,940 MiB) | 118.54 s | 13,728,018 B |

| axis | Run B | Run C |
|---|---|---|
| set-writes | skip=62 flex=144,158 slow=61,403 | **skip=61,437 flex=144,151 topJoin=5 union=0 slow=0** |
| major GC time | 41.10 s | 33.78 s |

Identity: byte-identical vs the Phase-1 binary on this tree; all 7 census witness lines
identical. vs Run B (`out.mlir` 13,724,267 → 13,728,018 B, +3,751 B — comparable): wall
−7.1 s (−2.2%, FLAT by protocol), minors 1379→1375, majors 13→12, promoted −1.0%, GC
time −5.35 s (−4.3%, mostly major: 41.10→33.78 s). Counters all move down, none up. The
census finding outranks the wall: the old 61,403-strong slow path was almost entirely
**concrete writes onto already-⊤ slots** (61,375 → now allocation-free skips), genuine
unions were **zero**, and ⊤-onto-members was 5 — the fresh-Point/Dict/unifyStep join
machinery had no real joins to perform on this workload. `setWriteSlow=0` across the
full self-compile: the defensive arm is measured dead (one more clean run licenses
deletion). elm-tests 13,104/12 and E2E ×3 1,675/1,675 also ran green on this tree
(pre-restructure); bootstrap deferred to the final sweep.

---

## Summary

One row per run, numbers only.

| Run | Wall (s) | Num Minor GCs | Num Major GCs | Promoted objects (MB) |
|---|---|---|---|---|
| A | 326.3 | 1348 | 14 | 12801 |
| B | 326.8 | 1379 | 13 | 13056 |
| C | 319.7 | 1375 | 12 | 12940 |
