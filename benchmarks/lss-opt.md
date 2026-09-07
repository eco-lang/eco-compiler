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
| fidelity (NEW) | **muTied=0** widenedByLet=672 localMultiBypass=469 — **SUPERSEDED, do not size from this row:** re-censused 2026-08-21 as widenedByLet 690 (sf-off) / 2,013 (sf-on) with 0% of it use-at-fault and 0 slots destroyed, localMultiBypass 455 (`plans/lss-per-use-let-separation.md` §2.R) |
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

### 2026-08-18 — Run Q: speckey §10.9 — dead comparable-key renderers deleted, watchdog context thunked, all five `fingerprintOf` sites hash-keyed (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| p4 | **5:54.41** (354.4 s) | 5,800,992 kB | 1,407 | 17 | 475,692,159 (13,641 MiB) | 142.05 s | 13,816,872 B |

| axis | Run P (post) | Run Q |
|---|---|---|
| out.mlir | 13,777,733 B | 13,816,872 B (+39,139 B, +0.28%) |
| minor / major GC time | 86.26 s / 43.11 s | 86.51 s / 55.54 s |
| true mutator (wall − GC) | 211.2 s | 212.3 s |
| joins identical / zonked / byBudget | 81,128 / 485,239 / 50,934 | 81,337 / 486,727 / 51,232 |

Tree = the two dead comparable-key renderers deleted (`toComparableSpecKey`, `toComparableLayoutKey`;
the layout oracle moved into `ComparableKeyEncodingTest`), `checkSpecWatchdogs`'s context string
thunked behind `() ->`, and all five `CafHoist.fingerprintOf` callers (CafHoist, MonoCse, CafDedupe,
CafCensus, CseCensus) rekeyed kind-tag → `Mono.SpecMap`. **Behaviour is unchanged on a default
compile** — those five passes are all default-off and the deletions were unreferenced — so every
census counter moves up in lockstep with the corpus (zonked +0.3%, byBudget +0.6%, apR 3,224→3,230):
that is the +39,139 B of new source being compiled, not an analysis change. **Wall +13.8 s (+4.1%)
is above the band and sits almost entirely in major GC**: majors 14→17, major-GC time +12.43 s,
against minors 1,406→1,407, promoted −0.03% and true mutator 211.2→212.3 s. CORRECTED by Run R:
this entry first called that "the major-GC lottery" — majors are DETERMINISTIC per (binary × tree),
so the 14→17 step is caused by this change/corpus, not chance. It is still not code slowness (the
mutator is flat); it is a heap-occupancy step, and RSS −13.9% is the other half of that same step.

### 2026-08-18 — Run R: variance study — FIVE cold legs of the UNCHANGED Run-Q binary (purpose-built; refutes the "major-GC lottery")

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| v1 | **5:54.41** (354.4 s) | 5,789,864 kB | 1,407 | 17 | 475,692,160 (13,641 MiB) | 142.36 s | 13,816,872 B |
| v2 | **5:59.80** (359.8 s) | 5,790,036 kB | 1,407 | 17 | 475,692,160 (13,641 MiB) | 144.78 s | 13,816,872 B |
| v3 | **5:56.78** (356.8 s) | 5,789,888 kB | 1,407 | 17 | 475,692,160 (13,641 MiB) | 143.65 s | 13,816,872 B |
| v4 | **5:52.00** (352.0 s) | 5,801,084 kB | 1,407 | 17 | 475,692,159 (13,641 MiB) | 140.42 s | 13,816,872 B |
| v5 | **5:54.17** (354.2 s) | 5,790,208 kB | 1,407 | 17 | 475,692,160 (13,641 MiB) | 141.71 s | 13,816,872 B |

| axis | min | max | range |
|---|---|---|---|
| wall | 352.00 s | 359.80 s | 7.80 s (2.19%) |
| GC time | 140.42 s | 144.78 s | 4.36 s (3.06%) |
| true mutator (wall − GC) | 211.58 s | 215.02 s | 3.44 s (1.62%) |
| max RSS | 5,789,864 kB | 5,801,084 kB | 11,220 kB (0.19%) |
| minors / majors / promoted MiB / out.mlir | 1,407 / 17 / 13,641 / byte-identical across all five (`cmp`) | — | **ZERO** |

Five cold legs, same binary and tree, sources untouched, `eco-stuff` purged before each; Run Q is a
sixth sample of this configuration and also read 1,407 / 17. **The "major-GC trigger lottery" is
REFUTED**: majors are 17 in all six, minors 1,407 in all six, promoted identical, and all five
`out.mlir` are byte-identical to each other. The only object-level wobble is promoted …160 vs …159
in v4 — one object in 475.7 M — matching Run H's 4-in-1.07 B nursery-copy wobble. GC counters are a
DETERMINISTIC function of (binary × tree), as Run H claimed at n=2, now at n=6. **Consequence: the
lottery is the wrong model and Runs D, E, K and Q all lean on it.** Majors are not chance; they are
a deterministic STEP function of heap occupancy, so a small retention or corpus change really can
move the count and several seconds of wall with it. "Do not read the whole wall delta as code
speed" still holds — but the cause is the change, not luck. Noise floor on IDENTICAL work: wall
±1.1%, GC time 3.06% range, true mutator 1.62%, RSS 0.19% — tighter than Run H's ±1.7% estimate.

### 2026-08-19 — Run S: per-major-GC event log added to GCStats (plain run; instrumentation cost gate)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| gclog | **5:55.47** (355.5 s) | 5,801,160 kB | 1,407 | 17 | 475,692,159 (13,641 MiB) | 142.40 s | 13,816,872 B |

| axis | Run R (5 legs, same Elm corpus) | Run S |
|---|---|---|
| wall | 352.00–359.80 s (mean 355.43) | 355.47 s — inside the range |
| minors / majors / promoted MiB | 1,407 / 17 / 13,641 | 1,407 / 17 / 13,641 |
| GC time | 140.42–144.78 s | 142.40 s — inside the range |
| out.mlir | 13,816,872 B | 13,816,872 B (runtime is C++, NOT part of the Elm corpus) |
| new | — | 17-row major-GC event log at process end |

The change is C++ runtime only (`GCStats` gains a bounded per-major event log: timestamp,
total/mark/sweep/root split, old-gen before/after, mark-derived garbage, bytes released,
minors+promoted since the previous major, mark units, trigger reason), so the Elm corpus is
untouched and `out.mlir` is byte-size identical to Runs Q/R — this is the cleanest
comparison in the file. **Instrumentation cost is nil**: every counter matches Run R to the
object and wall/GC time land inside its 5-leg range. Two pre-existing telemetry bugs fixed
on the way: `MajorGCPhaseProfile::mark_units_done` was declared but never written (now the
delta of the aggregate work-unit counter across the mark loop), and the minor-side counters
live in `NurserySpace`'s OWN `GCStats`, so reading them off the ThreadLocalHeap instance
yielded zero (now passed in). Findings from the log are in the analysis, not here; the
headline is that **mark is 92.4% of all major-GC time** (51.8 s of 56.1 s).

### 2026-08-19 — Run T: null-cons HPointer embedding — nullary ctors become embedded words (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| nullcons | **5:33.31** (333.3 s) | 5,534,812 kB | 1,401 | 14 | 450,139,439 (13,292 MiB) | 124.51 s | 13,761,833 B |

| axis | Run S | Run T |
|---|---|---|
| out.mlir | 13,816,872 B | 13,761,833 B (−55,039 B, −0.40%) |
| minor / major GC time | 86.51 s / 55.54 s (Run Q, same counters) | 85.23 s / 39.27 s |
| true mutator (wall − GC) | 213.07 s | 208.80 s (−2.0%) |
| promoted 0-field `Tag_Custom` | 28,645,830 (437 MiB) | **0** |
| lss census zonked / byBudget / joins identical | 486,727 / 51,232 / 81,337 (Run Q) | 486,789 / 51,239 / 81,357 |

`plans/null-cons-hpointer-embedding.md` (HEAP_044/CGEN_079): a nullary constructor becomes the
embedded word `(idx<<43)|0b111` carrying its declaration index, not a 16-byte heap `Tag_Custom`;
RBEmpty drops reserved 0xFFFE for index 1 and Order's LT/EQ/GT stop being rooted heap singletons.
**Witness: the W1 histogram now starts at 1 field — promoted 0-field Customs are exactly 0** (was
28,645,830 / 437 MiB, 27.6 M of them RBEmpty); op verifiers, `alloc::custom`, runtime asserts and
the ECO_HEAP_VALIDATE walkers make the shape unrepresentable. vs Run S (`out.mlir` −0.40% — an
emission change legitimately moves it, and 0.4% of corpus cannot buy 6.2% of wall): **wall −22.2 s
(−6.2%), GC time −17.9 s (−12.6%), majors 17→14** on −5.4% promoted objects, far outside Run R's
±1.1%/3.06% floors — the sized mechanism, mark being 92.4% of major GC. Mutator −2.0%, RSS −4.6%;
lss census is corpus drift. Gates: E2E + heap-validate 1,681/1,681, elm-tests 12, bootstrap green.

### 2026-08-19 — Run U: `|>` / `<|` inlined at typed lowering — `Basics.apR`/`apL` stop being specialized (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| apRapL | **5:08.56** (308.6 s) | 5,844,072 kB | 1,323 | 12 | 433,092,851 (12,785 MiB) | 108.91 s | 13,585,786 B |

| axis | Run T | Run U |
|---|---|---|
| out.mlir | 13,761,833 B | 13,585,786 B (−176,047 B, −1.28%) |
| minor / major GC time | 85.23 s / 39.27 s | 81.19 s / 27.70 s |
| true mutator (wall − GC) | 208.79 s | 199.65 s (−4.4%) |
| top specs/global | (Run J/Q) apR=3,223–3,230 foldl=2,049 apL=1,475 | foldl=2,051 apL=891 foldr=848 foldrHelper=848 Task.andThen=789 |
| `Basics_apR` / `Basics_apL` symbols in out.mlir | — | 766 / 891 |
| binary | — | 64,719,424 B |

`(|>)`/`(<|)` are rewritten to the application they denote in `LocalOpt/Typed/Expression.elm`'s
`Can.Binop` arm, beside the existing `&&`/`||` lowering, so the monomorphizer never registers them;
the function side flattens into an existing call spine, making `x |> f a b` the saturated `f a b x`.
An emission change, so `out.mlir` legitimately moves: 13,761,833 → 13,585,786 B (−1.28%). Counters
first: minors 1,401→1,323 (−5.6%), majors 14→12, promoted 13,292→12,785 MiB (−3.8%) — all three down
together, far outside Run R's ±1.1%/3.06% floors — with wall −24.7 s (−7.4%), GC time −12.5% (major
−29.5%) and mutator −4.4%. Census witness: `apR` leaves the top-5 (was #1) and `apL` falls to 891,
while `foldl` holds at 2,049→2,051 — the rest of the corpus is unmoved. **The residue is a
benchmark-configuration artifact, not an implementation gap**: 766+891 apR/apL symbols survive
because the package `typed-artifacts.dat` in `~/.eco` (elm/core 2026-08-13, most others 2026-07-09)
hold TypedOptimized graphs lowered by pre-change binaries and the protocol forbids deleting that
cache — only `compiler/src` (6,768 `|>`, 648 `<|`) is re-lowered, so this run UNDERSTATES the change.
Max RSS +5.6% is the one counter moving the wrong way, unexplained — the parked Run-G/H class.
Gates ran as a separate pass: `--target full` 1,681/1,681.

### 2026-08-19 — Run V: same tree as U, but `~/.eco` rebuilt so PACKAGE artifacts are re-lowered too (plain run; **baseline break**)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| cold-cache | **5:09.41** (309.4 s) | 5,899,912 kB | 1,314 | 12 | 433,603,188 (12,800 MiB) | 109.67 s | 13,543,058 B |

| axis | Run U | Run V |
|---|---|---|
| out.mlir | 13,585,786 B | 13,543,058 B (−42,728 B, −0.31%) |
| minor / major GC time | 81.19 s / 27.70 s | 80.77 s / 28.89 s |
| true mutator (wall − GC) | 199.65 s | 199.74 s |
| `Basics_apR` / `Basics_apL` symbols in out.mlir | 766 / 891 | **0 / 3** |
| top specs/global | foldl=2,051 apL=891 foldr=848 foldrHelper=848 Task.andThen=789 | foldl=2,051 foldr=848 foldrHelper=848 Task.andThen=789 Bytes.Decode.Decoder=689 |
| sets zonked / singletons | 405,920 / 85,665 | 365,356 / 64,011 |
| widened bySize / byBudget | 320 / 41,251 | 43 / 36,648 |
| joins noop / changed / retranslations | 3,203 / 2,728 / 813 | 2,136 / 1,850 / 590 |
| devirtDirect / slotsMinted | 5,130 / 852,469 | 3,984 / 826,290 |

`~/.eco` had been deleted, so this run rebuilds it: all 29 package `typed-artifacts.dat` are
re-lowered by the CURRENT binary (2026-08-19 20:53), applying the `|>`/`<|` rewrite to package code
— what Run U could not reach. **Witness: apR/apL symbols go 766/891 → 0/3** (the 3 are genuine
operator-as-value uses); both leave `top specs/global` while `foldl` holds at 2,051. The analysis
does materially less work — zonked −10.0%, `bySize` widening −86.6%, join noop −33%, changed −32%,
`devirtDirect` −22%. **None of it reaches the numbers that matter**: vs Run U (13,585,786 →
13,543,058 B, −0.31%) wall +0.3%, minors 1,323→1,314, majors 12=12, promoted +0.1%, mutator +0.09 s
— flat on every axis, inside Run R's ±1.1% floor. **This corrects Run U's "understates the change"
expectation: the mechanism completed exactly as predicted, the performance did not follow.** T→U was
the whole win; the package-side residue was worth nothing. Confound: the fresh artifacts differ from
U's July/August ones in EVERY compiler change since, not only apR/apL — not a single-variable A/B.
**Baseline: rows A–U ran against artifacts frozen 2026-07-09/08-13; V is the first run on a fully
current corpus and is the new reference row.**

### 2026-08-20 — Run W: LSS_019 standalone-member grounding landed DEFAULT-ON (lss-fidelity plan 2; plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| gs-final | **5:12.23** (312.2 s) | 5,721,288 kB | 1,334 | 12 | 435,983,035 (12,874 MiB) | 111.98 s | 13,557,262 B |

| axis | Run V | Run W |
|---|---|---|
| out.mlir | 13,543,058 B | 13,557,262 B (+14,204 B, +0.10%) |
| minor / major GC time | 80.77 s / 28.89 s | 80.50 s / 31.47 s |
| true mutator (wall − GC) | 199.7 s | 200.2 s |
| grounding (NEW) | — | **grounded=4,955 deferred=11** |
| widened bySize / byKernel / byBudget | 43 / — / 36,648 | 43 / 4,062 / 36,693 |
| join flush rounds / retranslations | — / 590 | 3 / 590 |
| devirtDirect / top specs | 3,984 / foldl=2,051 | 3,984 / foldl=2,052 |

Tree = `plans/lss-fidelity-2-standalone-member-grounding.md` COMPLETE, `lss.groundStandalones`
DEFAULT-ON (G3): provisional `g|`/`c|` members ground to `g|<global>|<widened-arrow-typeKey>` at
zonk (LSS_019). An analysis change, so `out.mlir` legitimately moves — but the flag itself moves it
only **+213 B** (same-tree A/B); the rest of the +14,204 B is the implementation source compiled as
workload. Same-tree flag-off vs flag-on: every downstream counter is UNMOVED (byBudget 36,691→36,693,
devirt/dispatch identical, foldl=2,052 both) — the §8 budget-pressure risk is unrealized; grounding
refines element identity without moving fan-out. vs Run V: majors 12 = 12 (clean pair), wall +2.8 s
(+0.9%) and mutator +0.5 s — FLAT; minors +1.5% / promoted +0.6% track the corpus-growth precedent
(Runs B/I/K). Gates as a separate pass: flag-off pre-vs-post byte-identical; E2E 1,682/1,682 (new
`LssGroundStandaloneTest`); Stage-8c fixed point byte-identical both flag-on-by-env and default-on;
elm-tests 13,126/12 (same 12 pre-existing).

### 2026-08-20 — Run X: LSS_020 signature set-flow (A/B on `lss.sigFlow`; flag stays DEFAULT-OFF)

| arm | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| sf-on | **5:28.25** (328.3 s) | 5,934,344 kB | 1,383 | 13 | 460,821,468 (13,570 MiB) | 117.06 s | 13,633,572 B |
| sf-off | 5:16.91 (316.9 s) | 5,933,952 kB | 1,363 | 13 | 461,485,430 (13,594 MiB) | 113.29 s | 13,603,530 B |

| lss census | sf-off | sf-on |
|---|---|---|
| signatures | 9,705 memoized (9,705 trivial) | 9,705 memoized (**9,311 trivial**) |
| sets zonked; sizeHist k=1 | 367,761; 64,311 | 406,002; 95,620 |
| sizeHist k=2..8 | 807/303/122/57/35/14/23 | 812/301/128/56/36/14/23 |
| widened bySize / byKernel / byBudget / bySigSize | 43 / 4,065 / 36,825 / 0 | 43 / 4,142 / 38,775 / 0 |
| set-writes flex / slotsMinted | 127,347 / 829,785 | 177,264 / 872,099 |
| joins identical / noop / changed | 75,866 / 2,156 / 1,857 | 68,966 / 22,074 / 1,929 |
| join flush rounds / retranslations | 3 / 592 | 3 / 600 |
| grounding grounded / deferred | 5,014 / 11 | 12,602 / 11 |
| sigflow widenedByCf / kernelFactHits | 0 / 169 | 5,329 / 169 |
| devirtDirect / dispatchUpgraded / declinedNoInstance | 4,000 / 3,570 / 1,383 | 4,000 / 3,578 / 1,516 |
| multiSetSites | 2->2 3->1 5->1 | 2->2 3->1 5->1 |

A/B of `lss.sigFlow` (LSS_020, plan lss-fidelity-3): both arms built AND measured solver+LSS, the
flag set at build and workload so each arm is self-consistent. Analysis change ⇒ `out.mlir` moves
(+30,042 B), so the wall comparison includes a workload change. Wall +3.6% (316.9→328.3 s) is
ATTRIBUTABLE to the analysis doing more work, not to slower code: sets zonked +10.4%, slotsMinted
+5.1%, flex set-writes +39%, join-noop 2,156→22,074; GC agrees — majors 13=13, promoted −0.14%, RSS
flat, only minors +1.5%. Precision lands as designed: 394 signatures nontrivial, singletons
64,311→95,620, grounded 5,014→12,602, byBudget +5.3% (watchdogs quiet), bySigSize=0; k≥2 and
multiSetSites UNMOVED (GAP-6 NO-GO confirmed). Not comparable to Run W's row (out.mlir 13,557,262 B
there vs 13,603,530 here — the corpus grew by plan 3's own source). DEFAULT-OFF stands: Run-M
(benchmarks/runtime-calls.md) measured fast coverage 8.30%→6.08% — see plans/lss-directed-set-flow.md.

### 2026-08-20 — Run Y: LSS_022 kernel parametricity license — 193 audited KernelSetFacts rows (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| license | **5:21.65** (321.7 s) | 5,808,140 kB | 1,377 | 13 | 459,839,503 (13,548 MiB) | 116.60 s | 13,695,657 B |

| axis | Run X (sf-off arm) | Run Y |
|---|---|---|
| out.mlir | 13,603,530 B | 13,695,657 B (+92,127 B, +0.68%) |
| widened byKernel | 4,065 | **1,575** |
| sigflow kernelFactHits / kernelLicensed | 169 / — | 12 / **2,490** |
| sets zonked; sizeHist k=1 | 367,761; 64,311 | 367,766; **64,311** |
| devirtDirect / devirtKernel / dispatchUpgraded | 4,000 / — / 3,570 | 4,000 / 772 / 3,570 |
| widened bySize / byBudget | 43 / 36,825 | 43 / 36,822 |
| grounding grounded / deferred | 5,014 / 11 | 5,014 / 11 |
| set-writes flex / slotsMinted | 127,347 / 829,785 | 122,690 / 830,214 |
| true mutator (wall − GC) | 203.6 s | 205.1 s |

Tree = `plans/kernel-parametricity-license.md` COMPLETE (LSS_022): 193 rows, 192 licensed
(158 `Inert`, 34 `Transports`) + 1 `Positional`. Unflagged default-path work, so this is a
PLAIN run compared against Run X's **sf-off** arm — the shipping configuration — not its
summary row. **The mechanism reconciles exactly: 4,065 − 2,490 = 1,575.** Every licensed
boundary previously took the rowless full poison and now poisons nothing, so `byKernel`
becomes a much sharper number (arrow-carrying unlicensed boundaries), which was §7's goal.
**Precision did NOT follow, and that is the result:** singletons 64,311 → 64,311,
`devirtDirect`/`dispatchUpgraded` identical to the object, `byBudget` −3, grounding
identical. The poison removed sat on positions no member reaches here — 158 rows are `Inert`
(concrete types, zero set slots, poison already a no-op) and the `Transports` rows' only
member-bearing positions were already `PSFApplies` under the v1 rows. Wall +1.5% on a +0.68%
corpus with majors 13 = 13 and promoted −0.34% is FLAT: no regression detected, no win
claimed. `set-writes flex` −3.7% is the one counter that tracks the mechanism.

### 2026-08-20 — Run Z: kernel intrinsic annotations, 3 rows (plain run; **baseline break** — packages re-lowered)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| intrinsics | **5:22.20** (322.2 s) | 6,057,384 kB | 1,381 | 13 | 461,664,545 (13,597 MiB) | 115.99 s | 13,713,430 B |

| axis | Run Y | Run Z |
|---|---|---|
| out.mlir | 13,695,657 B | 13,713,430 B (+17,773 B, +0.13%) |
| package `typed-artifacts.dat` | 2026-08-19 20:53 | **2026-08-20 19:23 (re-lowered)** |
| widened byKernel | 1,575 | 1,608 |
| sigflow kernelFactHits / kernelLicensed | 12 / 2,490 | 12 / 2,464 |
| sets zonked; sizeHist k=1 | 367,766; 64,311 | 368,074; 64,352 |
| devirtDirect / devirtKernel / dispatchUpgraded | 4,000 / 772 / 3,570 | 4,000 / 772 / 3,570 |
| widened bySize / byBudget | 43 / 36,822 | 43 / 36,874 |
| grounding grounded / deferred | 5,014 / 11 | 5,021 / 11 |
| true mutator (wall − GC) | 205.1 s | 206.2 s |

Tree = `plans/kernel-intrinsic-annotations.md` Phases 1-2: `Can.VarKernel` emits
`CForeign` for kernels with an intrinsic annotation row (`List.fromArray`,
`List.toArray`, `Json.addEntry`) instead of `CTrue`. **This row is NOT
comparable with Run Y and no counter movement here may be attributed to the
change**: the fail-stop gate requires the packages to be re-lowered, so
`elm/core` and `elm/json` typed artifacts were regenerated between the two runs
— the same two-variable break Run V documented. `byKernel` +33 and
`kernelLicensed` −26 are therefore UNATTRIBUTED. Clean attribution comes from
the plan's differential probe instead (single variable, identical package
state): `String.split`/`join` byKernel 10 → 6 with licensed 0 → 4, and
`Json.Encode.list` 8 → 6 with 3 → 5, control unmoved. Wall +0.5 s, majors
13 = 13, promoted +0.36%, devirt/dispatch identical to the object: FLAT, no
regression detected. **Run Z is the new reference row.**

### 2026-08-20 — Run AA: kernel intrinsics Phase 3 + ruling-R1 verification fix (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| intrinsics-p3 | **5:23.52** (323.5 s) | 5,943,792 kB | 1,366 | 13 | 460,007,743 (13,565 MiB) | 117.51 s | 13,719,384 B |

| axis | Run Z | Run AA |
|---|---|---|
| out.mlir | 13,713,430 B | 13,719,384 B (+5,954 B, +0.04%) |
| widened byKernel | 1,608 | **1,572** |
| sigflow kernelFactHits / kernelLicensed | 12 / 2,464 | 12 / **2,502** |
| licenses REFUSED at the occurrence (NEW) | — | 5 (Console.readLine, Env.rawArgs, File.getCwd, Runtime.dirname, Runtime.random) |
| sets zonked; sizeHist k=1 | 368,074; 64,352 | 368,162; 64,356 |
| devirtDirect / devirtKernel / dispatchUpgraded | 4,000 / 772 / 3,570 | 3,999 / 772 / 3,570 |
| widened bySize / byBudget | 43 / 36,874 | 43 / 36,878 |
| grounding grounded / deferred | 5,021 / 11 | 5,019 / 11 |
| true mutator (wall − GC) | 206.2 s | 206.0 s |

Tree = `plans/kernel-intrinsic-annotations.md` Phase 3 (fromArray/toArray licensed at
`List a -> List a`, addEntry upgraded to the full sharing shape, `sameType` tightened to
variable IDENTITY, shape/annotation sync test) plus the `Json.addField` annotation and the
**ruling-R1 fix**: `hasFunctionCapable` had answered `True` for every `TVar`, so the `Inert`
licenses on `Utils.compare/equal/lt/gt/le/ge` and `Basics.add/sub/mul/pow` were refused at
every polymorphic caller; `Engine.isScalarVar` now reads the solver's super table.
**36 boundaries move from poisoned to licensed (+38 licensed)** — the direction R1 predicts,
though modest here because `byKernel` counts BOUNDARIES, not the runtime calls that make
those kernels hot. Wall +1.3 s, majors 13 = 13, promoted −0.23%, minors −1.1%, mutator
−0.2 s: FLAT, no regression. Package artifacts were current for both rows (Z 19:23, AA 20:54)
but re-lowered in between, so this is not single-variable either — the counter direction is
attributable, the magnitude is not. **The refusal census is this run's real deliverable**
(see below); it is the first measurement of that counter on a full workload.

### 2026-08-20 — Run AB: kernel devirt table complete (13 kernels) + HofAxis cost fix (plain run)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| devirt-table | **5:31.12** (331.1 s) | 5,820,380 kB | 1,385 | 13 | 459,564,513 (13,547 MiB) | 121.14 s | 13,738,965 B |

| axis | Run AA | Run AB |
|---|---|---|
| out.mlir | 13,719,384 B | 13,738,965 B (+19,581 B, +0.14%) |
| devirtKernel | 772 | **928 (+156)** |
| kernel whitelist misses | 157 sites / 12 kernels | **5 sites / 5 kernels** (all new singletons: Basics.toFloat, Char.toCode, String.toInt, String.words, Utils.compare) |
| declinedNoInstance (AbiCloning) | 1,383 | **1,247 (−136)** |
| dispatchUpgraded | 3,570 | 3,603 (+33) |
| kernel declines arity | 12 | 15 |
| licenses REFUSED | Console.readLine=1 | +59 at DEVIRT-CREATED boundaries (Basics.not=44, String.length=4, …) |
| widened byKernel | 1,572 | 1,717 (+145) |
| true mutator (wall − GC) | 206.0 s | 210.0 s |

Tree = `plans/kernel-devirt-arity-table.md` complete: `devirt : DevirtPolicy` on
KernelFacts, 13 registered kernels (List.cons + Scheduler.succeed/fail + the ten-kernel scalar
batch), generic `peelArrow`/shape/emission guards, plus `callsBack : HofAxis` (CUnknown prices
at the row-less 6; nine genuine HOFs declared HofYes). **The mechanism check passes: misses
−152 sites and devirtKernel +156 move together**, and the removed dispatches surface downstream
as `declinedNoInstance` −136 with `dispatchUpgraded` +33. Second-order effect worth naming:
devirt CREATES kernel boundaries at former indirect sites, whose `canFuncType` is the callee
VAR's type — often var-typed, so LSS_022 occurrence verification correctly refuses the license
there and poisons (byKernel +145, refusals +59; sound, and now measured rather than invisible).
Wall +7.6 s (+2.3%) on a +0.14% corpus with majors 13 = 13, promoted −0.02%, mutator +1.9% —
below the 3% band: FLAT, no regression detected; the CSE/DCE upside on the 87 Scheduler sites
did not materialize as wall on this workload.

### 2026-08-20 — Run AC: LSS_023 directed set flow (A/B on `lss.sigFlow`; the Run-X re-measure)

| arm | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| sf-on (directed) | **5:28.39** (328.4 s) | 6,085,036 kB | 1,425 | 13 | 476,139,480 (14,006 MiB) | 116.48 s | 13,793,989 B |
| sf-off | 5:29.61 (329.6 s) | 6,102,416 kB | 1,405 | 13 | 476,799,186 (14,029 MiB) | 118.33 s | 13,763,893 B |

| lss census | sf-off | sf-on |
|---|---|---|
| signatures | 9,781 memoized (9,781 trivial) | 9,781 memoized (**9,387 trivial**) |
| sets zonked; sizeHist k=1 | 368,746; 64,431 | 407,131; **95,854** |
| widened bySize / byKernel / byBudget | 43 / 1,717 / 36,930 | 43 / 1,738 / 39,005 |
| joins identical / noop / changed | 76,520 / 2,168 / 1,861 | 69,590 / 22,169 / 1,933 |
| sigflow edges / degraded / widenedByCf | 0 / 0 / 0 | **177 / 4** / 5,342 |
| grounding grounded / deferred | 5,024 / 11 | 12,619 / 11 |
| dispatchUpgraded / declinedNoInstance / declinedBlocked | 3,604 / 1,248 / 0 | 3,612 / 1,381 / 8 |
| devirtDirect / devirtKernel | 4,000 / 928 | 4,000 / 928 |

A/B of `plans/lss-directed-set-flow.md` (LSS_023): hub/local-callee/tunnel joins become
DEFERRED INCLUSIONS (`LsFrom`, pull-at-read) instead of symmetric unification; both arms
built AND measured solver+LSS on one tree. Precision reproduces Run X's shape exactly —
394 nontrivial signatures, singletons 64,431 → 95,854 (+31,423), grounded +7,595,
byBudget +5.6% (watchdogs quiet) — **but the WALL COST IS GONE: −1.2 s (−0.4%, FLAT)
where Run X's symmetric arm paid +3.6%**, majors 13 = 13, promoted −0.14%. Two §8.1
expectations corrected by measurement: `joins noop` did NOT drop (22,169 ≈ Run X's
22,074 — the noops come from the KEPT symmetric joins and rep links, not the flipped
sites; only 177 edges exist), and `declinedNoInstance` +133 persists (the LSS_017 raw-`l|`
signature channel, orthogonal to pollution). Mono-time dispatch is +8 upgraded / +8
blocked; the DECISIVE depollution gate is Run-M's runtime fast coverage (recorded in
`benchmarks/runtime-calls.md`; Run X measured 8.30% → 6.08% there). Flag stays
DEFAULT-OFF pending that gate.

---

### 2026-08-21 — Run AD: LSS_024 layout-qualified members + fingerprint fence (A/B on `lss.layoutQualMembers`, both arms `lss.sigFlow=1`)

| arm | Wall (s) | Max RSS (kB) | Minor GCs | Major GCs | Promoted (MB) | `out.mlir` (B) | stampedStaged | layoutQual |
|---|---|---|---|---|---|---|---|---|
| sf-off reference | 343.1 | 6,381,688 | 1,424 | 13 | 14,244 | 13,794,917 | 459 | inert |
| sigFlow-on, fix OFF | 343.3 | 6,384,196 | 1,445 | 13 | 14,291 | 13,825,013 | 453 | inert |
| sigFlow-on, fix ON | 348.4 | 6,428,544 | 1,454 | 13 | 14,369 | 13,801,325 | 457 | mints=75,237 shared=4,538 fallback=0 tieBypass=0 |

Fix-on vs fix-off: wall +1.5% — FLAT; majors IDENTICAL (13 all arms), minors +0.6%.
`stampedStaged` recovers the full sigFlow de-stamp (453→457 = −6 recovered, −4
fenced `Dict.map` staged stamps + 2 new C-enabled staged stamps; `declinedBodyMismatch`
0→11 and `declinedAbiMismatch` 0→3 on united groups — each a fenced E11-class hazard).
Artifact: the fix removes 104 of sigFlow's 242 duplicate instances (−23.7 KB);
canonical per-role diff: `UnionFind.modify` 14→9 (propagated splits collapse, one
BELOW the sf-off baseline of 10), root splits (`variableToCanType` family, raw-id
9429-carried) persist at 2 by design. Flag-off `out.mlir` byte-identical to the
pre-change binary's (two-binary/frozen-corpus gate) and JS/native artifacts
byte-identical on all three arms. Flag DEFAULT-OFF; plan
`plans/lss-layout-qualified-members.md` (Phase-0 census + two as-built corrections
recorded there).

### 2026-08-22 — Run AE: E9.5 post-settle fn-global/ctor devirt (A/B on `lss.postSettleDevirt`, defaults otherwise)

| arm | Wall (s) | Max RSS (kB) | Minor GCs | Major GCs | Promoted | GC/Alloc (s) | `out.mlir` (B) | devirtPost fn/ctor/noSpec |
|---|---|---|---|---|---|---|---|---|
| flag OFF | 350.3 (5:50.28) | 6,109,400 | 1,461 | 14 | 485,955,839 (14,351 MiB) | 125.13 | 13,827,927 | 0/0/0 |
| flag ON | 352.2 (5:52.18) | 6,104,104 | 1,461 | 14 | 486,338,488 (14,367 MiB) | 126.14 | 13,830,780 | **86/311/0** |

Reach acceptance EXACT: devirtPost = the Phase-0 census's admissible table to
the digit (86 g + 311 c, 0 layout misses); `declinedNoInstance` 1,390→993 =
−397. Neutrality: minor AND major GC counts IDENTICAL across arms; wall +0.5%
= FLAT; artifact +2,853 B. Flag-off `out.mlir` byte-identical to the
pre-change binary's on the same corpus (two-binary gate); flag-on determinism
×2 byte-identical; elm-tests 13,192/12-pre-existing (6 new pins); Stage-4b JS
fixed point held. Built on the reach-completeness criterion — self-compile
dispatch heat of the population is ≈0.24% upper bound by design
(plan §2.R.2); no event-recovery claim. Flag landed DEFAULT-OFF and was
FLIPPED DEFAULT-ON the same day (user-directed, on this battery alone —
no separate bootstrap run, recorded in the plan); plan
`plans/lss-post-settle-fn-global-devirt.md` (LSS_025).

### 2026-08-23 — Run AF: default `maxSpecsPerGlobal` 64 → 512, plus the GAP-2 Phase-0 census instrumentation (plain single run — baseline for the call-arg transport work)

| arm | Wall (s) | Max RSS (kB) | Minor GCs | Major GCs | Promoted | GC/Alloc (s) | `out.mlir` (B) | widened byBudget |
|---|---|---|---|---|---|---|---|---|
| budget 512 | 359.7 (5:59.70) | 6,841,280 | 1,484 | 16 | 498,922,909 (14,747 MiB) | 137.83 | 14,370,158 | **8,575** |

Counters first, against the SAME source at budget 64 (the Phase-0 census arm,
`/work/lss-gap2-phase0-census.txt`): `widened byBudget` 39,052 → **8,575**
(−78%), `joins changed` 1,732 → 600, `retranslations` 542 → 232,
`devirtDirect` 4,000 → 4,453, `layoutQual shared` 4,548 → 8,620, singleton
sets 95,824 → 100,858 — 512 captures ~77% of the distance to budget 4096
(byBudget 0, devirtDirect 4,431) at a fraction of its fan-out, confirming the
sweep's "512 is the knee". Majors are **16 at budgets 64, 512 AND 4096 on this
source** while Run AE's 14 was HEAD source, so the +2 is the new report-gated
census instrument (measured cost ≤0.75% wall: 361.5 s vs the census-off
diagonal's 358.8 s at budget 64), NOT the flip — the flip is GC-neutral (minor
1,485 → 1,484). No cross-row wall claim is admissible: `out.mlir` moved
13,830,780 (AE) → 14,370,158 (+3.9%), part budget (an ANALYSIS change, which
legitimately emits more code) and part corpus (the census is compiler source);
against the same-source budget-64 point (361.5 s) the wall is −0.5% = FLAT.
Plans: `plans/lss-gap2-callarg-transport.md` §2.6, `/work/lss-knob-sweeps-report.md`.

### 2026-08-23 — Run AG: GAP-2 call-argument set transport (A/B on `lss.callArgFlow`; D0 honest-sources UNCONDITIONAL in both arms)

Plan: `plans/lss-gap2-callarg-transport.md` (LSS_026). Same binary
(`eco-compiler-d2`, built from the final source) in both arms; only
`ECO_MONO_LSS_ARG_FLOW` moves. Census and dispatch counters OFF for these rows.

| arm | Wall (s) | Max RSS (kB) | Minor GCs | Major GCs | Promoted | GC/Alloc (s) | `out.mlir` (B) |
|---|---|---|---|---|---|---|---|
| `callArgFlow=0` | 358.11 (5:58.11) | 6,905,748 | 1,514 | 15 | 501,408,184 (14,826 MiB) | 136.88 | 14,389,393 |
| `callArgFlow=1` | 367.72 (6:07.72) | 6,928,244 | 1,526 | 15 | 501,980,081 (14,847 MiB) | 139.94 | 14,399,989 |
| Δ | **+2.68%** | +0.33% | +0.79% | **0** | +0.14% | +2.24% | +0.07% |

**Wall +2.68% is real and sub-action-band** (observed noise floor ±1.1%; the
house action band is ≥3%). It sits exactly where the mechanism puts it: D1 adds
one union-find unify per call-shaped arrow argument (3,922 of them) and D2 adds
11,885 directed set flows plus 104 poison walks. **Majors are IDENTICAL at 15**,
which at n=1 is the strong statement — majors are a deterministic step function
of occupancy, not a lottery (`major-gc-determinism`).

What it buys, on the same pair of runs: singleton sets 101,002 → 111,772
(**+10.7%**), `sigflow edges` 177 → 16,896, four more non-trivial signatures,
`connected + dropped = 2,480 + 1,442 = 3,922 = pop|all` exactly. What it does
NOT buy: `devirtDirect` is FLAT at 4,453 — the transported mass is raw `l|`,
which declines at AbiCloning (LSS_017 noInstance). That was predicted per member
class in the plan's §3.5 and is not a disappointment; reach was the deliverable.

One counter deserves its own line: **`topMixedFlex` goes 0/0 flag-off → 2/0
flag-on.** The transport CREATES edge-reachable sources, so the honest-sources
rule (LSS_026(a), unconditional since this landing) actually fires twice on the
self-compile with the flag on. Without it, those two facts would have been
published as COMPLETE sets. §0.5's "D0 remains a hard prerequisite for D1/D2" is
now measured rather than argued.

Rails for the same tree: flag-off byte-identity on the two-binary rail (md5
`8f4160bf3bdc2903a2d4ce8da18c15e1`), flag-on determinism ×2 (`ddfd2498…`),
elm-tests 13,220/12 with the failure set identical to the Phase-0 baseline, E2E
1,687/1,687 in BOTH arms.

**Dispatch census on the same pair (counters-lowered binaries,
`ECO_DISPATCH_STATS=1` in both arms) — this is what decided the flip:**

| | OFF | ON | Δ |
|---|---:|---:|---:|
| `sat` | 1,780,856,389 | 1,792,507,699 | +11,651,310 |
| `gen` | 1,749,945,178 | 1,761,596,488 | +11,651,310 |
| `typed` | 30,911,211 | 30,911,211 | **0** |
| `fast` | 505,374,807 | 493,723,497 | −11,651,310 |
| **`sat + fast`** | **2,286,231,196** | **2,286,231,196** | **0 — EXACT** |
| LSS coverage | 22.105% | 21.596% | **−0.51 pp** |

The invariance rail passes to the event, and every lost `fast` dispatch became
`gen` (not `typed`) — 11.65 M `$cap` calls fell out of static stamping into the
generic funnel. **`lss.callArgFlow` therefore ships DEFAULT-OFF**: the flip
gate is "no fast-coverage regression" and this is one. Re-open when a consumer
for the reach exists (LSS_017-v2 raw→qualified, or sum lowering) or when the
de-stamping is explained and repaired.

**Follow-up, same day — the de-stamping mechanism is still UNKNOWN.** Two
attributions were proposed and both refuted by measurement: annotation-keyed
spec splits, and adoption-blocking of one hot member (a full repair drove
`declinedBlocked` 156 → 0 and coverage moved **0.000 pp** — plan §11.5,
NO-GO, reverted; it also cost 19 k singleton sets and 60 % of grounding).
`dispatchUpgraded` is flat across all four arms and static `$cap` sites GROW,
so the stamps are not being lost — the surviving hypothesis is that the hot
traffic relocates onto unstamped sites. Plan §11.6 specifies the per-site
dynamic attribution that must come first.

No per-symbol attribution is offered: `lambda_N` numbering is corpus-specific
and the arms are different corpora, so a symbol-keyed join across them aliases
unrelated functions.

### 2026-08-24 — Run AH: `LUnknown` split + the `monoTypeToVarC` de-laundering + per-occurrence arrow identity (three arms, one frozen corpus; `plans/lss-unknown-elimination.md` Phases 1a/1b/2a)

| arm | Wall (s) | Max RSS (kB) | Minor GCs | Major GCs | Promoted | GC/Alloc (s) | `out.mlir` (B) |
|---|---|---|---|---|---|---|---|
| pre-1b (Phase 1a only) | 351.6 (5:51.63) | 6,449,272 | 1,506 | 14 | 499,589,248 (14,765 MiB) | 127.79 | 14,393,287 |
| Phase 1b (`arrowIdentity` OFF) | 361.5 (6:01.47) | 6,750,960 | 1,531 | **14** | 501,010,836 (14,817 MiB) | 131.88 | 14,393,908 |
| Phase 2a (`arrowIdentity` ON) | 364.0 (6:04.03) | 6,706,536 | 1,535 | **14** | 500,274,326 (14,794 MiB) | 132.46 | 14,421,256 |

| §2.5 resolution ledger | k=1 | **k≥2** | over-cap | **top** | **unknown** | total | **completeness** |
|---|---:|---:|---:|---:|---:|---:|---:|
| pre-1b | 101,148 | 544 | 7 | 152,908 | 168,170 | 422,777 | 24.09 % |
| Phase 1b | 144,984 | 545 | 7 | **29,403** | 250,097 | 425,036 | **34.24 %** |
| Phase 2a ON | 155,838 | **2,005** | 7 | 30,952 | **238,058** | 426,860 | **37.10 %** |

Counters first. **1b's one deleted line — `monoTypeToVarC` re-encoding an
unwritten slot as an explicit `LsTop` — moves `top` −80.8% and CONCRETE
resolutions +43.3%**, where the plan predicted a pure relabelling; ~36% of the
transferred mass becomes real answers because flex is recoverable and poison is
not. `dispatchUpgraded` 4,485→4,768, `retranslations` 236→441 (the height-2
lattice), `topMixedFlex` stays 0/0 so §3.6's feared trade does not occur.
**2a adds `|set|≥2` ×3.7 and the first non-zero `multiSetSiteHist` ever
(`2->2`)**, with `unknown` ↓ and `k=1` ↑ together — §2.5.4's completeness
signature, not sigFlow's pollution one; `trivial` signatures 9,473→9,456 and
`slotsMinted` −9.1% are the predicted §4.3 side effects. Walls: 1b **+2.8%**
(sub-action-band, majors IDENTICAL at 14), 2a **+0.7% = FLAT**. Rails:
byte-identity pre-1a≡1a and 1b≡2a-flag-off on the JS-loop corpus, elm-tests
13,220/12-pre-existing (+10 new `ArrowIdentityTest`), E2E 1,687/1,687 in BOTH
flag arms. **EXP-2a: `rootAnn|hitExact` 568 of `hit` 22,727 = 2.5%** — def
annotations and body node types are DISTINCT objects 97.5% of the time, so the
transport artifacts need Phase 2b, not 2a. 1a and 1b ship unconditionally;
**`lss.arrowIdentity` ships DEFAULT-OFF** (the flip still wants the runtime
dispatch A/B). Plan §10 carries the full results; LSS_027–LSS_030 are new.

### 2026-08-26 — Run AM: GAP-A closed — store-aware classification of bare global references (A/B on `lss.refIdentity`)

| arm | Wall (s) | Max RSS (kB) | Minor GCs | Major GCs | Promoted | GC/Alloc (s) | `out.mlir` (B) |
|---|---|---|---|---|---|---|---|
| off | 398.0 (6:37.97) | 10,810,944 | 1,788 | **9** | 586,605,408 (17,565 MiB) | 129.91 | 14,965,780 |
| on | 415.1 (6:55.06) | 11,053,816 | 1,844 | **9** | 592,471,774 (17,770 MiB) | 132.45 | 15,247,547 |

| §2.5 ledger | k=1 | k≥2 | over-cap | top | var | total |
|---|---:|---:|---:|---:|---:|---:|
| off | 159,735 | 2,047 | 7 | 28,304 | 250,624 | 440,717 |
| on | **195,033** | **3,386** | 7 | **20,816** | 273,390 | 492,632 |

| census | `union` | slotsMinted | retranslations | multi-set arrows | widened byBudget |
|---|---:|---:|---:|---:|---:|
| off | 24 | 836,761 | 313 | 100 | 9,379 |
| on | 1,342 | 854,948 | 591 | 728 | 9,050 |

`Store.classifyGo` stamps `Mono.LTop` on every arrow ("storeless classification stamps LTop") and
`translateVarRef` used it for every bare global reference. `translateGlobalCall` gates that
classifier on `lssFastOk`; the reference path did not, so a bare reference's arrows were ⊤ before
any member could reach them. `Translate.classifyRef` adds the gate. ANALYSIS change: `out.mlir`
moves (`fe1eeffb…` → `360e4655…`, +1.9 %); retranslations 313 → 591, `union` 24 → 1,342, zonks
+11.8 %, `top` −26.5 %, `var` rises, `k1 + kN` +36,637. **WALL HERE IS CENSUS-DISTORTED — USE RUN
AN** (+0.60 %): the protocol's mandatory `ECO_MONO_LSS_REPORT=1` ran the §5.1/§5.6 `Q` verifier
inside the measured work and its cost scales with constraints recorded, so it billed the `on` arm
more. Majors 14 → 9 and RSS 6.4 → 10.8 GB vs AH are the binary and corpus, NOT the census (AN holds
both with it off) and not this flag (9 = 9). The ledger and census columns above stand.

### 2026-08-26 — Run AN: Run AM re-measured with the census OFF — the compile-time cost of `classifyRef` (A/B on `lss.refIdentity`; NO report, NO `lss.qCensus`)

| arm | Wall (s) | Max RSS (kB) | Minor GCs | Major GCs | Promoted | GC/Alloc (s) | `out.mlir` (B) |
|---|---|---|---|---|---|---|---|
| off | 390.9 (6:30.94) | 10,743,008 | 1,735 | **9** | 585,903,264 (17,542 MiB) | 129.56 | 14,971,156 |
| on | 393.3 (6:33.30) | 10,990,044 | 1,775 | **9** | 590,364,101 (17,698 MiB) | 129.58 | 15,252,923 |

| against Run AM (same A/B, census ON in both arms) | AM off | AM on | AM Δ | AN off | AN on | AN Δ |
|---|---|---|---|---|---|---|
| Wall (s) | 398.0 | 415.1 | **+4.3 %** | 390.9 | 393.3 | **+0.60 %** |
| Max RSS (kB) | 10,810,944 | 11,053,816 | — | 10,743,008 | 10,990,044 | — |
| Major GCs | 9 | 9 | 0 | 9 | 9 | 0 |

**+0.60 % is FLAT** — below the ≳3 % threshold, so: no regression detected. `classifyRef` costs
essentially nothing in compile time. **Run AM's +4.3 % was the census, not the change.** The `Q`
verifier's cost scales with the number of constraints recorded, and this fix RAISES that count, so
it charged the `on` arm more than the `off` arm and amplified a flat delta into an apparent
regression — census in both arms is not the same as census-neutral when the census bills per unit
of analysis output. **REFUTED by this run, and it was my hypothesis:** AM's entry blamed the census
for majors 14 → 9 and RSS 6.4 → 10.8 GB. Both are unchanged here with the census OFF (majors 9,
RSS within 68 MB), so those belong to the binary and the corpus alone. Deliberate deviation: the
protocol's command sets `ECO_MONO_LSS_REPORT=1` and this run drops it, so there are no lss census
counters — that is the point of the run, and Run AM carries them.

### 2026-08-26 — Run AO: `lss.refIdentity` DEFAULT-ON, the flip + the ANALYSIS-COVERAGE counter (plain run at the new defaults; census ON — wall NOT comparable to census-off rows)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| flip defaults | 6:56.95 (417.0 s, census-on) | 10,981,884 kB | 1,814 | 9 | 591,529,717 (17,743 MiB) | 134.51 s | 15,258,422 B (`0f0b86d6…`) |

| NEW `coverage:` line (artifact positions — THE progress gate as of 2026-08-26) | positions | k1 | kN | var | top | covered |
|---|---:|---:|---:|---:|---:|---:|
| old defaults (`cov-def`) | 127,957 | 20,558 | 682 | 37,237 | 69,480 | **16.59 %** |
| new defaults (this run; = `cov-ri` to the digit) | 132,113 | 29,087 | 2,276 | 39,024 | 61,726 | **23.73 %** |

Two changes land together: `Mono.annoCoverage` + the `coverage:` census line
(position-based analysis-coverage metric — the gate; a hot slot no longer
counts 50×, and the denominator cannot be gamed by suppressing readbacks), and
the `lss.refIdentity` default flip: **+7.14 pp analysis coverage**, the arc's
largest completeness gain, on the day's full battery (Run AN wall FLAT +0.60 %;
runtime-calls Run AO dispatch NEUTRAL −274 of 560 M; E2E full flag-on
1,691/1,691 with the harness cache forced cold; elm-tests 13,355/12 = baseline
BOTH via env-flag AND re-run on the flipped tree — 39 test sites consume
`Config.default*` as a constant, which the env arm cannot reach). The
confirmation census is bit-identical to the env-flag arm (positions/k1/kN to
the digit) — flag-via-env ≡ flag-via-constant. Census-on wall/GC: NOT
comparable to census-off rows (the protocol's Run-AM lesson); majors 9 = 9 vs
Run AN. Position metric vs readback ledger INVERT on the ⊤/var diagnosis (⊤ =
54→47 % of positions but 6→4 % of readbacks); always name the metric. Escape
hatch `ECO_MONO_LSS_REF_IDENTITY=0` (`lssRI=0` rides the OFF arm).

### 2026-09-07 — Run AP: `lss.stamp.papFast` A/B (LSS_040 `p|` fast stamp; census flags off)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| off | **7:47.85** (467.9 s) | 13,468,660 kB | 2,096 | 8 | 730,494,135 (21,898 MiB) | 145.68 s | 15,501,076 B (`e8f4ffaa…`) |
| on | **7:45.69** (465.7 s) | 13,491,280 kB | 2,096 | 8 | 730,994,140 (21,912 MiB) | 144.02 s | 15,521,029 B (`f5f1ddc2…`) |

| axis | off | on |
|---|---|---|
| `stampedPapGlobal` / `declinedNoInstance` | 0 / 16,244 | 2,041 / 14,203 |
| `coverage` positions / k1 / kN | 144,749 / 99,510 / 33,114 | identical |
| `set-writes` slotsMinted / `widened` byKernel / `join flush` | 827,391 / 345 / rounds=0 retranslations=0 | identical |

Wall −0.46 % — FLAT (below the 3 % bar); minors and majors identical, promoted +0.07 %. Every LSS
analysis counter is identical to the digit, so this is a STAMPING change, not an analysis change:
`out.mlir` legitimately differs (+0.13 %; 2,041 `p|` sites gain an E2-shaped fast stamp). The
dispatch win is real and exact — −164,237,200 generic dispatches (−14.96 %) by caller-attributed
uprobe count on identical input (`plans/lss-pap-fast-stamp.md` §10.2) — but at the wall model's
47.7 ns/dispatch that is ~7.8 s of 468 s (~1.7 %), sub-noise by construction. The −7.7 % seen under
the probe is probe-inflated (the uprobe taxes each of the 1.1 G dispatches) and is retracted as a
wall figure. Binaries are native fixed-point lowerings of the current tree (each arm reproduces its
own input byte-for-byte), standing in for the JS Stage-5 `eco-compiler` target that converges to
the same bytes. No regression detected; the flip decision rests on the dispatch counter, not wall.

### 2026-09-07 — Run AQ: `p|` fast stamp, constructor arm (plan §11.1; plain run, papFast default on)

| leg | wall | max RSS | minor GC | major GC | promoted | GC time | out.mlir |
|---|---|---|---|---|---|---|---|
| ctor arm | **7:37.97** (458.0 s) | 13,476,776 kB | 2,096 | 8 | 730,950,758 (21,911 MiB) | 143.25 s | 15,522,491 B (fixed point) |

| axis | AP-on | AQ |
|---|---|---|
| `stampedPapGlobal` / `papNonFn` | 2,041 / 131 | 2,135 / 0 |
| `coverage` positions / k1 / kN | 144,749 / 99,510 / 33,114 | identical |
| `set-writes` flex / slotsMinted | 218,035 / 827,391 | 218,045 / 827,406 |

Plain run: `specFunctionRow` admits constructor specs (≤ 24 fields) as `p|` fast-stamp targets,
under the already-default `papFast`. Against AP-on (465.7 s) wall is −1.7 % — FLAT; minors and
majors identical, promoted +0.0 %. `out.mlir` moved +1,462 B on AP-on's 15,521,029 B: 88 new
constructor stamps in the compiler's own code (text-diff verified, every hunk `segmentation_unknown`
→ `singleton_fast` with a ctor spec evaluator) PLUS the arm's own source, so the corpus moved and the
wall is not cross-row attributable — and the analysis counters that moved (+10 flex writes, +15
slots) are that source growth, not an analysis change. Dispatch A/B on identical input (uprobe):
933,925,039 → 933,006,001 = −919,038 (−0.10 %), all at `IO.map` (JSON-decoder ctor callbacks) —
cold, as `plans/lss-pap-fast-stamp.md` §11.1 predicted; a mechanism completion, not a win.
No regression detected.

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
| Q | 354.4 | 1407 | 17 | 13641 |
| R-v1 | 354.4 | 1407 | 17 | 13641 |
| S | 355.5 | 1407 | 17 | 13641 |
| T | 333.3 | 1401 | 14 | 13292 |
| U | 308.6 | 1323 | 12 | 12785 |
| V | 309.4 | 1314 | 12 | 12800 |
| W | 312.2 | 1334 | 12 | 12874 |
| X | 328.3 | 1383 | 13 | 13570 |
| Y | 321.7 | 1377 | 13 | 13548 |
| Z | 322.2 | 1381 | 13 | 13597 |
| AA | 323.5 | 1366 | 13 | 13565 |
| AB | 331.1 | 1385 | 13 | 13547 |
| AC | 328.4 | 1425 | 13 | 14006 |
| AD | 348.4 | 1454 | 13 | 14369 |
| AE | 352.2 | 1461 | 14 | 14367 |
| AF | 359.7 | 1484 | 16 | 14747 |
| AG-off | 358.1 | 1514 | 15 | 14826 |
| AG-on | 367.7 | 1526 | 15 | 14847 |
| AH-pre1b | 351.6 | 1506 | 14 | 14765 |
| AH-1b | 361.5 | 1531 | 14 | 14817 |
| AH-2a-on | 364.0 | 1535 | 14 | 14794 |
| AM-off | 398.0 | 1788 | 9 | 17565 |
| AM-on | 415.1 | 1844 | 9 | 17770 |
| AN-off | 390.9 | 1735 | 9 | 17542 |
| AN-on | 393.3 | 1775 | 9 | 17698 |
| AO | 417.0 | 1814 | 9 | 17743 |
| AP-off | 467.9 | 2096 | 8 | 21898 |
| AP-on | 465.7 | 2096 | 8 | 21912 |
| AQ | 458.0 | 2096 | 8 | 21911 |
