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

### 2026-08-17 — Run D: substrate Phase 3 — ctx-threaded set writes, no S copy per node (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| p3 | **5:31.10** (331.1 s) | 6,589,376 kB | 1,378 | 14 | 455,009,823 (13,071 MiB) | 130.23 s | 13,727,612 B |

| axis | Run C | Run D |
|---|---|---|
| minor GC time | 84.75 s | 83.60 s |
| major GC time | 33.78 s | 46.61 s |
| true mutator (wall − GC) | 200.81 s | 200.57 s |
| set-writes | skip=61,437 flex=144,151 topJoin=5 union=0 slow=0 | skip=61,453 flex=144,188 topJoin=5 union=0 slow=0 **slotsMinted=957,478** |

Pure refactor: `SetWriteCtx` threading removes the full-S copy per set write and per node
visited by `poisonGo`/`spineGo`; the census gains only the `slotsMinted` rider. vs Run C
(`out.mlir` 13,728,018 → 13,727,612 B, −406 B, comparable): wall +11.4 s (+3.6%), just above the
band — but **entirely major GC**, majors 12→14 and major GC time 33.78→46.61 s (+12.83 s), while
minor GC time FALLS (84.75→83.60 s) and **true mutator is 200.81→200.57 s, i.e. unchanged**.
Counters first: this is the major-GC trigger lottery, not the refactor. The eliminated S copies
leave no trace in minors (1375→1378) or promoted (+1.0%) either, so Phase 3 is **cost-neutral** —
the ~32-field copy per visited node was real but is not something this workload is bound by, and
the phase's justification is now structural. The rider is the yield: **957,478 slots minted against
205,646 total set writes ⇒ 78.5% of minted arrow slots are never written**, corroborating Run B's
78.0% ⊤/unconstrained zonk reads from the mint side and sizing Phase 5, the only phase attacking it.

### 2026-08-17 — Run E: substrate Phase 4a — `joinAnnotationsChanged` rebuild elision (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| p4a | **5:17.01** (317.0 s) | 6,462,264 kB | 1,377 | 12 | 446,295,895 (12,818 MiB) | 117.01 s | 13,732,605 B |

| axis | Run D | Run E |
|---|---|---|
| minor GC time | 83.60 s | 83.30 s |
| major GC time | 46.61 s | 33.69 s |
| true mutator (wall − GC) | 200.57 s | 199.70 s |
| joins | identical=80,889 noop=4,566 changed=3,424 completion=33,539 | identical=80,892 noop=4,565 changed=3,423 completion=33,547 **completionNoop=33,543** |

**The census is the result: 33,543 of 33,547 completion joins add nothing (99.99%)** — only FOUR
completion joins in the whole self-compile change the stored type. That site was rebuilding a full
type tree (fresh nodes, re-mixed hashes) and discarding it, unconditionally, per completed
body-bearing spec; it is now a pointer return. The registry path's `noop=4,565` sheds its
rebuild-plus-second-`==`-walk too. vs Run D (`out.mlir` 13,727,612 → 13,732,605 B, +4,993 B — the
new code is in the corpus): **promoted 13,071 → 12,818 MiB (−1.9%)**, majors 14→12, GC time
130.23→117.01 s, wall −4.3%. Judge on counters: promoted is the durable signal and is now the
lowest of the three runs (C 12,940 / D 13,071 / E 12,818), which is exactly what eliding tree
rebuilds should do. The wall and GC-time deltas are inflated by the major count reverting to 12,
and true mutator is FLAT (200.57→199.70 s), so do not bank the 4.3%.

### 2026-08-17 — Run F: substrate Phase 4b — mint-key memo by Global (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| p4b | **5:22.92** (322.9 s) | 6,580,920 kB | 1,385 | 12 | 455,273,041 (13,073 MiB) | 118.13 s | 13,747,678 B |

| axis | Run E | Run F |
|---|---|---|
| minor GC time | 83.30 s | 83.12 s |
| major GC time | 33.69 s | 34.99 s |
| true mutator (wall − GC) | 199.70 s | 204.43 s |

**NO-GO as specified — and this comparison is the clean one: majors are 12 in BOTH runs**, so
none of the delta is the trigger lottery that muddied C→D→E. Every counter moves the wrong way:
promoted 12,818 → 13,073 MiB (+2.0%), minors 1377→1385, true mutator 199.70→204.43 s (+2.4%),
wall +1.9%. `out.mlir` grew 13,732,605 → 13,747,678 B (+15,073 B, +0.11%) — the memo is a fair
chunk of new compiler source — but 0.11% more corpus cannot buy 2.4% more mutator time. Cause,
verified after the run: `spineDepthForGlobal` → `declaredArityOf` does
`DMap.get TOpt.toComparableGlobal g s.env.toptNodes` on the SAME occurrence path (again per
`Link` hop), so the string the memo exists to eliminate is still built for every arrow-typed
global. 4b removed the mint key and the `kernelAliasOf` probe, left the third build standing, and
added two `HashMap` probes plus memo inserts per occurrence. The cost class is real; its owner is
`env.toptNodes`'s string-keyed `DMap`, not the mint key. Revert or subsume — do not tune.

### 2026-08-17 — Run G: substrate Phase 4c — `env.toptNodes` DMap → HashMap (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| p4c | **5:11.50** (311.5 s) | 6,196,520 kB | 1,376 | 12 | 444,867,878 (12,784 MiB) | 110.75 s | 13,739,414 B |

| axis | Run E | Run G |
|---|---|---|
| minor GC time | 83.30 s | 81.22 s |
| major GC time | 33.69 s | 29.51 s |
| true mutator (wall − GC) | 199.70 s | 200.55 s |
| max RSS | 6,462,264 kB | 6,196,520 kB |

Base is Run E — Run F's tree was reverted. Majors are 12 in both (`out.mlir` 13,732,605 →
13,739,414 B, +6,809 B). Wall 317.0 → 311.5 s decomposes as GC −6.26 s against mutator +0.85 s;
max RSS −4.1% (−259 MB); major GC −4.18 s at an unchanged major count. **The per-probe build
thesis is REFUTED**: minor GC cycles — this file's allocation-pressure proxy — move 1377 → 1376
(0.07%), so the ~100k+ discarded key strings were never meaningful nursery pressure. **The
retention explanation this entry first offered for the memory numbers is ALSO refuted, on two
counts** (checked after the fact, not before): ~15-50k entries × ~50-100 B of retained comparable
key is 1-5 MB, two orders of magnitude short of 259 MB; and `initState` converts a COPY while
`Builder/Generate.elm:794-801` keeps `typedGraph` — hence the original `DMap` and its strings —
live across the whole call, so nothing is freed and 4c can only ADD live heap. **Cause of the RSS
and major-GC movement is therefore UNEXPLAINED and most likely heap-growth/GC-timing variance at
n=1.** Treat Run G as FLAT. Do not build on either mechanism without a repeat-run variance check.

### 2026-08-17 — Run H: variance re-leg — the UNCHANGED Run-G binary, re-run cold (Phase 5a item 0)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| p4c-again | **5:16.72** (316.7 s) | 6,196,956 kB | 1,376 | 12 | 444,867,878 (12,784 MiB) | 113.91 s | 13,739,414 B |

Same binary and tree as Run G, one purpose-built re-leg to settle whether Run G's memory movement
was noise. **It was not: max RSS reproduces to 0.007%** (6,196,520 → 6,196,956 kB), every GC
counter is identical (minors 1376, majors 12, promoted to the object; copied-in-nursery differs by
4 objects in 1.07B), and the output is byte-identical — RSS is effectively DETERMINISTIC per
(binary × tree) in this runtime. Two consequences. (1) Run G's −259 MB vs Run E is REAL and
reproducible; its mechanism stays unknown (the retained-key arithmetic still caps that explanation
at ~1-5 MB) — plausibly a heap-growth quantization effect where a small live-heap change moves a
capacity-doubling decision; parked, not worth chasing. (2) The run-to-run noise floor on IDENTICAL
work is wall ±~1.7% (311.5 vs 316.7 s) and GC time ±~0.7 s — calibration for reading every other
adjacent-row delta in this file.

### 2026-08-17 — Run I: Phase 5a load-layer sizing census (plain run; counters only)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| p5a | **5:26.99** (327.0 s) | 6,593,176 kB | 1,391 | 13 | 457,742,239 (13,142 MiB) | 121.76 s | 13,742,709 B |

| new census line | value |
|---|---|
| points | total=27,931,402 **load=23,826,311** slots=958,411 **poisonLoads=140 poisonPoints=345** items=41,887 |
| loads | shared=973,097 sharedArrows=8,948 isolated=5,304 isolatedArrows=123,125 |

The sizing census Phase 5 is gated on; analysis and the gate verdict live in the plan's 5a
findings. Headlines: the load path mints 85.3% of all Points (23.8M of 27.9M; ~21.5 per load,
~667 per item), the never-written arrow slots are only 4.0% of load-path mints, and the
"load-purely-to-poison waste class" is **140 loads / 345 Points in the whole self-compile** —
nil, refuting the plan's `poisonCallBoundary` assumption (the 4,109 kernel poisons walk
already-loaded types). Total Points = 2.6% of copied-in-nursery events (27.9M / 1,087.8M).
vs Run H (`out.mlir` +3,295 B): wall +10.3 s, minors 1376→1391, promoted +2.8% — the census's
own cost, dominated by the now-unconditional per-load `lssStats` fold; a useful natural
experiment (≈+13M promoted objects moved wall only ~3%) and a candidate to re-guard later.
`--stats` and perf legs are separate passes, recorded in the plan.

### 2026-08-18 — Run J: lss-fidelity-1 landed — MONO_030 watchdogs + fidelity counters + LSS_018 μ-tie (A/B: muTie off/on)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| off (default) | **5:41.55** (341.6 s) | 5,888,740 kB | 1,406 | 16 | 468,906,390 (13,453 MiB) | 133.86 s | 13,772,597 B |
| on (ECO_MONO_LSS_MU_TIE=1) | **5:46.75** (346.8 s) | 5,877,232 kB | 1,406 | 16 | 468,906,390 (13,453 MiB) | 136.19 s | 13,772,597 B |

| axis | value (both arms) |
|---|---|
| fidelity (NEW) | **muTied=0** widenedByLet=672 localMultiBypass=469 |
| widened | bySize=462 byKernel=4,109 byBudget=50,904 |
| signatures | 9,651 memoized (9,651 trivial) |
| unqualifiedLambdaMints / declinedBlocked / watchdog trips | 0 / 0 / 0 |
| top specs/global | apR=3,223 foldl=2,049 apL=1,475 foldrHelper=843 foldr=842 |
| true mutator (wall − GC) | off 207.7 s (Run I: 205.2 s) |

Tree = plan lss-fidelity-1 landed (watchdogs both engines, fidelity counters, μ-tie behind
`lss.muTie` default-off). vs Run I: `out.mlir` 13,742,709 → 13,772,597 B (+29,888 B — the new
compiler source IS the corpus), majors 13→16, and wall +14.5 s decomposes as GC +12.1 s with
true mutator 205.2 → 207.7 s — inside the Run-H ±1.7% noise floor: no regression detected.
Minors 1391→1406 (+1.1%), promoted +2.4% — consistent with corpus growth + the per-item demand
scan + per-created-spec checks. **The census is the result: muTied=0 — the μ-tie-eligible
population is EMPTY on the self-compile**, so `widenedByBudget=50,904` is legitimate fan-out
(apR/foldl chains), not spiral burn; the fork-plan §6.5 spiral is unrealized here and the guard
stays armed for pathological workloads. The on arm confirms it mechanically: **byte-identical**
`out.mlir` (cmp), identical GC counters — flag inert on this workload, LSS_005-clean to default
on. GAP-9 sizing: 672 + 469 counterless-⊤ events vs `topSiteShapes local=7,361` — minor
components; plan 3's per-use separation leans PARK. Poly-rec fixture now errors in seconds
(was: infinite hang — see the plan's §1.1/§7).

### 2026-08-18 — Run K: fidelity-1 census REMOVED — true implementation cost vs the G/H baseline (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| impl-only | **5:43.84** (343.8 s) | 5,941,520 kB | 1,401 | 16 | 469,383,317 (13,464 MiB) | 133.88 s | 13,770,177 B |

| axis | Run H (baseline) | Run K |
|---|---|---|
| out.mlir | 13,739,414 B | 13,770,177 B (+30,763 B, +0.22%) |
| true mutator (wall − GC) | 202.8 s | 210.0 s (+3.5%) |
| minor / major GC time | ~81-85 s / 29.5 s | 85.4 s / 48.5 s |
| max RSS | 6,196,956 kB | 5,941,520 kB (−4.1%) |

Tree = Run J minus its one-shot census (fidelity counters deleted; μ-tie demand scan +
`lambdaQualified` recording now gated on `lss.muTie`). The census question closes at ZERO: vs
Run J (`out.mlir` 13,772,597 → 13,770,177 B) wall +2.3 s, minors 1,406→1,401, majors 16=16,
promoted +0.08% — all inside the Run-H ±1.7% floor. True implementation cost vs G/H: minors
1,376→1,401 (+1.8%), promoted 12,784→13,464 MiB (+5.3%), majors 12→16 with major-GC time
29.5→48.5 s carrying most of the +27 s wall; true mutator +3.5%. Attribution: the promoted
growth is proportionally consistent with this workload's corpus-growth precedent (Run B:
+8.8 KB source → +2.0% promoted; Run I: +3.3 KB → +2.8%; here +30.8 KB → +5.3%) — dominated
by the implementation source being COMPILED as workload, with the EXECUTING cost
(per-created-spec `countByGlobal` + `typeNodesWithin` + watchdog check) bounded by the
residual ≤1-2% mutator, unresolvable at n=1; majors follow promoted occupancy (trigger chain,
not code slowness). RSS −4.1% vs H is unexplained (same parked class as Run G's −259 MB). No
frozen H-era corpus exists (no git in this container), so a corpus-controlled A/B is
unavailable — this is the attribution floor.

### 2026-08-18 — Run M: LSS_018 μ-tie ON (B3 default-flip arm; A/B vs Run K's off arm)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| muTie on | **5:45.60** (345.6 s) | 5,963,236 kB | 1,401 | 16 | 469,398,756 (13,463 MiB) | 133.46 s | 13,770,177 B |

| axis | Run K (off) | Run M (on) |
|---|---|---|
| out.mlir | 13,770,177 B | 13,770,177 B — **byte-identical (cmp)** |
| minor / major GC | 1,401 / 16 | 1,401 / 16 |
| promoted | 13,464 MiB | 13,463 MiB |
| max RSS | 5,941,520 kB | 5,963,236 kB (+21.7 MB) |
| census | `muTie: tied=0 qualifiedRecorded=0` | `muTie: tied=0 qualifiedRecorded=36,650` |

Same binary, workload flag only (`ECO_MONO_LSS_MU_TIE=1`). **The flag is free and
behavior-neutral on this workload**: byte-identical MLIR, GC counters identical to the
object, wall +1.8 s (+0.5%, FLAT). The mechanism IS armed — `qualifiedRecorded=36,650`
is the `lambdaQualified` table the scan consults — and `tied=0` re-confirms the Run-J
finding that the self-compile has no qualification spiral; the +21.7 MB RSS is that
table. Not a null result: the tie is proven to work by a forced-spiral fixture
(`MuTieTest`: 65 specs → 2, where 65 = `maxSpecsPerGlobal` + seed, i.e. flag-off the
BUDGET is the only terminator). On that evidence `muTie` was flipped DEFAULT-ON (B3) —
free here, load-bearing on spiral-shaped workloads. Also this run's gate: the fork-plan
§7 repro (self-compile under all-globals keying) completes, `unqualifiedLambdaMints=0`.

### 2026-08-18 — Run N: F-2A budget sweep, re-run with the spiral μ-tied (one binary, budget the only variable)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| N=64 (shipping; = Run M) | **5:45.60** (345.6 s) | 5,963,236 kB | 1,401 | 16 | 469,398,756 (13,463 MiB) | 133.46 s | 13,770,177 B |
| N=256 | **5:47.84** (347.8 s) | 5,948,304 kB | 1,416 | 16 | 471,522,185 (13,534 MiB) | 132.72 s | 14,212,878 B |
| N=1024 | **5:49.07** (349.1 s) | 5,941,128 kB | 1,425 | 16 | 471,161,411 (13,524 MiB) | 134.37 s | 14,711,603 B |

| axis | N=64 | N=256 | N=1024 |
|---|---|---|---|
| out.mlir vs N=64 (code-size proxy) | — | +3.21% | +6.84% |
| wall vs N=64 | — | +0.6% | +1.0% |
| widened byBudget | 50,904 | 29,185 | 13,935 |
| muTie tied / qualifiedRecorded | 0 / 36,650 | 0 / 38,246 | 0 / 40,146 |

All three points run `ECO_MONO_LSS_MU_TIE=1` (the B3 default) on one binary, so this is
the pure fan-out-policy curve now that LSS_018 — not the budget — terminates the
qualification spiral. **Majors are 16 in all three legs**, so the comparison is free of
the trigger lottery. Raising the budget buys progressively less relief for a linear-ish
code-size price: byBudget widening 50,904 → 29,185 → 13,935 while `out.mlir` grows
+3.2% → +6.8%; wall is FLAT throughout (+1.0% at 16× the budget), and at N=1024 there
are STILL 13,935 widening events, so no budget in this range fully satisfies demand.
Against the historical F-2A (+4.36% binary, ~+6% mono wall at N=1024): code growth is
comparable, but the wall cost has essentially vanished — the substrate work since then
(Runs C/E/G) absorbed it. `tied=0` at every budget re-confirms this workload has no
spiral. **Decision: `maxSpecsPerGlobal` stays at 64** — this is a measurement, not a
default change; the curve is the pricing sheet for anyone who wants more fan-out.

### 2026-08-18 — Run O: speckey Phase 3 site 1 — `monoMemo.callMemo` Dict String → `Mono.SpecKeyMap` (A/B: pre/post, two binaries, one frozen corpus)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| pre | **5:39.49** (339.5 s) | 5,815,420 kB | 1,402 | 15 | 468,053,855 (13,434 MiB) | 128.39 s | 13,772,811 B |
| post (site 1) | **5:36.13** (336.1 s) | 5,691,148 kB | 1,402 | 15 | 468,076,607 (13,431 MiB) | 127.75 s | 13,772,811 B |

| axis | pre | post |
|---|---|---|
| out.mlir | 13,772,811 B | 13,772,811 B — **byte-identical (cmp)** |
| minor / major GC time | 84.76 s / 43.61 s | 84.53 s / 43.20 s |
| every lss census line | identical | identical |

`plans/speckey-optimization.md` §10.2: the M2b ground-memo key stops being a rendered
string (`gkey ++ "|" ++ arg keys ++ "->" ++ result key`) and becomes
`Mono.SpecKey global (mFunction LTop args result)`, probed on the `specHashOf` Int the
node already carries. **Byte-identical output is the gate and it passed** — the
equivalence relied on (`eqKeySpec` ≡ `toComparableMonoType` equality, pinned by
ComparableKeyEncodingTest) holds in practice, which is the only cheap detector for a
key that merges calls it should separate. Counters first: minors 1,402 = 1,402 and
majors 15 = 15 — an unusually clean pair — promoted +0.005%, so allocation pressure is
unmoved. Wall −3.4 s (−1.0%) is FLAT by protocol: no regression detected, and no win
claimed. Max RSS −124 MB (−2.1%) is the one real move; §10.2 predicted it (the memo is
global and used to retain every key string) but promoted being flat argues against that
mechanism, so treat it as the Run-G/H parked class, not as confirmation.

### 2026-08-18 — Run P: speckey Phase 3 site 2 — `NumberMultiEntry.instances` Dict String → `Mono.SpecMap` (A/B on one corpus; output change ACCEPTED)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| pre (site 1 only) | **5:38.87** (338.9 s) | 6,747,948 kB | 1,406 | 14 | 475,960,204 (13,649 MiB) | 128.46 s | 13,777,733 B |
| post (sites 1+2) | **5:40.58** (340.6 s) | 6,740,568 kB | 1,406 | 14 | 475,839,753 (13,645 MiB) | 129.38 s | 13,777,733 B |

| axis | pre | post |
|---|---|---|
| out.mlir | 13,777,733 B | 13,777,733 B — same SIZE, **content DIFFERS** (byte 1,907,828) |
| minor / major GC time | 85.43 s / 43.02 s | 86.26 s / 43.11 s |
| lss census (all lines) | zonked 485,239; byBudget 50,934; joins 81,128/4,582/3,431; apR 3,224 foldl 2,051 | **identical, every line** |

§10.3. Both arms compile the SAME corpus, so this isolates the binary. **The output
change is expected and accepted (§10.4): `SpecMap` iterates in insertion order where
`Dict String` iterated lexicographically by rendered type, and `buildLocalDefs` emits one
def per instance in iteration order.** Identical byte SIZE with differing content is the
signature of a pure permutation. **§10.4's prediction that spec counts would shift is
REFUTED: every lss census counter is identical across the arms** — the reorder changes
emission order and SpecId assignment order, not the spec population or the LSS analysis.
Wall +1.7 s (+0.5%) FLAT, minors 1,406 = 1,406, majors 14 = 14, promoted −0.025%. Gates
for an accepted output change: two cold runs byte-identical to each other
(deterministic), `ECO_MONO_VALIDATE=1` clean (MONO_029), Stage-4b bootstrap fixed point
converged, `--target full` 1,675/0, elm-tests 13,118/12 (same 12 pre-existing).

---

## Summary

One row per run, numbers only.

| Run | Wall (s) | Num Minor GCs | Num Major GCs | Promoted objects (MB) |
|---|---|---|---|---|
| A | 326.3 | 1348 | 14 | 12801 |
| B | 326.8 | 1379 | 13 | 13056 |
| C | 319.7 | 1375 | 12 | 12940 |
| D | 331.1 | 1378 | 14 | 13071 |
| E | 317.0 | 1377 | 12 | 12818 |
| F | 322.9 | 1385 | 12 | 13073 |
| G | 311.5 | 1376 | 12 | 12784 |
| H | 316.7 | 1376 | 12 | 12784 |
| I | 327.0 | 1391 | 13 | 13142 |
| J | 341.6 | 1406 | 16 | 13453 |
| K | 343.8 | 1401 | 16 | 13464 |
| M | 345.6 | 1401 | 16 | 13463 |
| N-256 | 347.8 | 1416 | 16 | 13534 |
| N-1024 | 349.1 | 1425 | 16 | 13524 |
| O | 336.1 | 1402 | 15 | 13431 |
| P | 340.6 | 1406 | 14 | 13645 |
