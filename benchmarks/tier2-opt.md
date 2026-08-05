# Tier-2 Opt Track — Stage-7a Cold-Cache Benchmarks

Tracks the wall/RSS/allocation impact of the tier-2 optimization track
(`plans/opt-tier2-cons-fusion.md` — residual list-traversal deletion and
successors) on the standard bootstrap workload. Append one labelled section
per run.

---

## Recording instructions (fixed — keep every entry uniform)

**Per run:** give it a **label** (Run A, Run B, …). Record **wall time**,
**max RSS**, and the **number and size of heap allocations** from the GC
stats exit dump (`Objects allocated`, `Bytes allocated`), plus
`Minor GC cycles`, `Objects promoted`, `Major GC cycles` (never report a
wall without its majors — trigger-lottery lesson), `Total GC/Alloc time`,
and the output `.mlir` byte size (workload-constancy check). Describe the
run in **max 10 lines of text** — no extensive write-ups; keep the labelled
entries uniform in appearance, stats recorded, and briefness.

**Summary table:** maintained at the **bottom of this file** — one row per
run: label, wall time, total heap allocation. Just the table, no write-up.

**Allocation-count caveat (census §18.3):** the standard binary's HEAP_034
inline-alloc fast path bypasses the per-tag counter, so `Objects allocated`
undercounts codegen'd constructs (~6× on this workload). The figure is
comparable **run-to-run** only for unchanged lowering; when a track
optimization is expected to move allocation, add a separate census leg with
an `ECO_INLINE_ALLOC=0`-lowered binary and record it explicitly as such.

---

## Methodology (repeat exactly each time; adapted from `benchmarks/runtime-calls.md`)

**Workload — cold-cache Stage 7a, constant-config.** The tested
`eco-compiler` binary compiling the entire compiler front-end
(`compiler/src/Terminal/Main.elm`, ~243 modules) to MLIR. The workload runs
under the **cheap fixed configuration** — `ECO_MONO_ENGINE=subst`, no LSS,
no borrow (both default-off under subst) — so the job the binary executes
stays essentially constant across track changes and the measurement isolates
**how fast the optimized binary runs**, undistorted by the recursive tax of
solver/LSS/borrow running *as* workload.

**Binary — the thing being tested.** Built with **solver + LSS + borrow ON
plus every track optimization under test**: this is the artifact whose
performance the track is improving. `build` preset (RelWithDebInfo,
asserts + GC-stats ON — the standard bootstrap config; ~2.6× slower than
release but deterministic). Note: `ECO_BORROW=1` without report/reify is
inert-by-construction today (the Phase-6 pass self-skips); it is set anyway
so the build line already carries every track knob as they become real.

**Two independent engine knobs** (do not confuse): the **build engine** (env
at the `cmake --build` step — how the binary itself is compiled) vs the
**workload engine** (env at the `make` run — how the binary monomorphizes
what it compiles). Here: build = solver+LSS+borrow+track-opts; workload =
subst, always.

**Cache reset — delete `eco-stuff/` immediately before every run; do NOT
touch sources.** `rm -rf build/compiler/build-kernel/eco-stuff` is the
honest cold-cache reset (touching mtimes is fragile; engine changes are
invisible to mtime). **Never delete `~/.eco`** (warm package cache).

**Testing is a separate pass** — never mix gate runs into a benchmark; they
pollute timings and the `eco-stuff/` cache.

**Commands** (run from `/work`):

```bash
BK=build/compiler/build-kernel

# Phase 1 — build the tested binary (repeat when the track changes):
# NINJA IS ENV-BLIND (discovered Run B): with no source change, an env-only
# flavor change does NOT rerun Stage 5 — delete its outputs to force it.
rm -f "$BK/bin/eco-compiler.mlir" "$BK/bin/eco-compiler"
rm -rf "$BK/eco-stuff"
ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 ECO_BORROW=1 ECO_AGG_PROMOTE=1 \
    cmake --build build --target eco-compiler          # + further track-opt env vars as they land
cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-compiler-borrowopt"

# Phase 2 — benchmark it (throwaway leg first to warm the OS page cache,
# then the recorded leg; BOTH legs cold in eco-stuff):
for LEG in warmup measured; do
  rm -rf "$BK/eco-stuff"
  ( cd "$BK" && ulimit -c 0 && \
      ECO_MONO_ENGINE=subst \
      /usr/bin/time -v -o "borrowopt-$LEG.time" \
      ./bin/eco-compiler-borrowopt make --optimize --kernel-package eco/compiler \
          --local-package eco/kernel=/work/eco-kernel-cpp \
          --output=bin/borrowopt-out.mlir /work/compiler/src/Terminal/Main.elm \
          > "borrowopt-$LEG.stdout" 2> "borrowopt-$LEG.stderr" )
done
# Report the measured leg. Wall + Max RSS from the .time file; allocation
# stats from the GC dump in .stdout; output size from bin/borrowopt-out.mlir.
```

For an A/B against a prior run, `cmp` the two `borrowopt-out.mlir` — the
subst-mode output must stay **byte-identical** across track changes (the
track optimizes the binary, not the semantics of what it emits); a size or
byte diff means the workload moved and walls are not comparable.

---

## Runs

### 2026-08-05 19:30 UTC — Run G: K7 read-only interning for the `Disabled` callers (**subst −2.0% wall, −2.5% promotion, majors 10→9; solver unaffected**)

`plans/mono-comparable-key-optimization.md` K7 §16: `Intern` gains a `ReadOnly`
mode that probes but never inserts, so `hashCons` returns the table it was handed
on BOTH paths — a read-only traversal therefore needs no state threading, only an
extra argument. `applySubstPureRO` wraps the EXISTING recursion; `Specialize`'s
16 sites and `unifyCallSiteDirect*`'s 4 now lend `accum.intern`. Census: subst
composite `hashCons` arriving `Disabled` **42.04% → 0.15%**, probe hit **98.06%**.
Subst pairs **−4.21 s/−5.01 s (−1.85%/−2.21%)** at −9,258,285 promoted (−2.52%)
and −2,929 objects; GC time covers 73%/70% of it, RSS flat (unlike Run E's
−16.4% — peak RSS is set outside the monomorphizer here). **The solver never
calls `TypeSubst`**, and measures so: objects +1, promotion =, majors 12=12, wall
+1.05%/−0.91% — noise both ways. `.mlir` **byte-identical** under BOTH engines.
Gates: elm-tests 13,063/12 known, E2E **1619/1619**, bootstrap EXIT=0 (both fixed points).

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:41.83** subst (base 3:46.84; r1 3:43.26/3:47.47) | 5,176,332 kB (base 5,178,332) | 376,384,280 (base 376,387,209) | 18,298.94 MB (base 18,299.04) | 848 (base 850) | **357,488,232** (95.0%; base 366,746,517) | **9** (base 10) | 81.40 s (base 84.92) | 12,959,381 B (≡ base) |
| **5:43.01** solver (base 5:46.15; r1 5:42.93/5:39.38) | 5,386,172 kB (base 5,389,976) | 579,055,820 (base 579,055,819) | 46,273.95 MB (base 46,273.95) | 1422 (=base) | 385,666,259 (66.6%; =base) | 12 (=base) | 111.92 s (base 113.35) | 13,415,623 B (≡ base) |

### 2026-08-05 16:00 UTC — Run F: K6 on the SOLVER engine (**solver −5.07% wall, −7.04% promotion, −13.2% RSS, 3 fewer majors**)

`plans/mono-comparable-key-optimization.md` §15: the K6 `Intern` table threaded
through the solver's own producers — `Store.classifyGo` and `Store.zonkToMono`'s
`ZonkCtx` (the two recursive type builders), `Zonk.canTypeToMonoWithI`,
`cachedSchemeMono`, and `Intern.widenSets` for the spec-registry key. Table home
is a new `S.intern`, made room for by grouping the three M2 memos into
`S.monoMemo` (`S` sat exactly at the native 32-slot record scan cap). Output
**byte-identical** to BOTH baselines under BOTH engines (solver 13,414,246 B;
subst 12,958,010 B) — sharing is still not observable. Interleaved same-source
triples vs `eco-compiler-k4fix` (pre-K6) and `eco-compiler-k6-substonly`:
**solver 5:33.80 vs 5:51.61 = −17.81 s (−5.07%)**, r1 −17.14 s (−4.85%); vs
k6-substonly −20.65 s (−5.83%), r1 −4.45%. **Promotion −29.2M (−7.04%)**, **max
RSS −847,728 kB (−13.15%)**, **majors 10 vs 13**, GC time −16.28 s — which
covers 91% of the wall delta. The mechanism is RETENTION and the numbers say so
cleanly: against k6-substonly, objects allocated move **+0.02%** (+140,659)
while promotion falls 6.96% — this change allocates nothing and keeps 29M fewer
objects alive. **Subst is flat**: +2.19 s (+0.98%) at −477 objects, +0.04%
promotion, equal majors (9=9) — inside the 1.87–2.54 s same-binary spread
measured across these rounds, and there is no mechanism for a real subst cost
since the solver code does not execute there. Gates: elm-tests 13,061/12 known
(3 new K6 tests incl. an `Intern.widenSets` ≡ `Mono.widenSets` differential),
E2E 1619/1619, bootstrap green incl. BOTH fixed points. **Raw walls are NOT
comparable to Run E** — the workload is the compiler's own source, which this
change edits; all legs here compile the same tree, so the triples are internally
valid.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **5:33.80** solver (k4fix 5:51.61, k6sub 5:54.45; r1 5:36.34/5:53.48/5:51.99) | 5,599,448 kB (k4fix 6,447,176; k6sub 6,432,136) | 578,903,113 (k4fix 594,600,469; k6sub 578,762,454) | 46,263.44 MB (k4fix 46,622.70) | 1438 (k4fix 1448) | 385,929,900 (66.7%; k4fix 415,153,413; k6sub 414,784,293) | 10 (k4fix 13; k6sub 13) | 105.92 s (k4fix 122.20; k6sub 124.37) | 13,414,246 B (≡ both) |
| **3:45.56** subst (k4fix 3:58.36, k6sub 3:43.37) | 5,605,656 kB (k6sub 5,594,200) | 376,270,422 (k6sub 376,270,899) | 18,293.01 MB (k6sub 18,293.02) | 866 (=k6sub) | 367,270,883 (97.6%; k6sub 367,132,890) | 9 (=k6sub) | 83.10 s (k6sub 81.97) | 12,958,010 B (≡ both) |

### 2026-08-05 14:00 UTC — Run E: K6 construction-time hash-consing (**subst −2.17% wall, −16.4% RSS; solver flat**)

`plans/mono-comparable-key-optimization.md` K6: an `Intern` table
(`Compiler.AST.Intern`, structure → canonical object, keyed by `specHashOf` and
decided by EXACT `==`) threaded through `TypeSubst.applySubstPureI` and out
through `applySubstFV`'s 52 `Specialize` call sites, plus an `a == b ||` fast
path on `eqKeySpec`/`eqKeyLayout`. Output **byte-identical** both engines (subst
12,956,798 B; solver 13,413,498 B) — sharing is not observable. Same-source
interleaved pairs vs `eco-compiler-k4fix`: **subst 3:46.33 vs 3:51.35 = −5.02 s
(−2.17%)**, r1 −4.90 s (−2.11%), equal majors (10=10); **promotion −23.5M
(−6.15%)** and **max RSS −1,001,496 kB (−16.4%)** — the retention mechanism §13
said no allocation count could predict, and GC time (−5.71 s) covers the whole
wall delta. **Solver is +0.53%/+0.93%** (5:40.54 vs 5:37.39): K6 threads only
the subst engine — `MonoSolver` builds its types in `Zonk`, not `TypeSubst` — so
the only live change there is `identicalOr` (objects −15.8M from skipped
`case ( a, b )` tuples), and the delta is one extra major GC (12 vs 11) at
+0.03% promotion. Gates: elm-tests 13,058/12 known, E2E 1619/1619, bootstrap
green incl. BOTH fixed points. No census leg: every figure that decides this
(promotion, RSS, majors, GC time) is GC-measured, so the inline-alloc caveat
touches only the `Objects allocated` percentage.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:46.33** subst (base 3:51.35; r1 3:47.66/3:52.56) | 5,113,520 kB (base 6,115,016) | 375,458,591 (base 394,063,375) | 18,234.64 MB (base 18,661.13) | 863 (base 879) | 358,646,365 (95.5%; base 382,136,977) | 10 (=base) | 83.60 s (base 89.31) | 12,956,798 B (≡ base) |
| **5:40.54** solver (base 5:37.39; r1 5:39.28/5:37.49) | 7,055,140 kB (base 7,042,752) | 576,877,132 (base 592,663,234) | 46,106.28 MB (base 46,467.59) | 1434 (base 1443) | 405,420,508 (70.3%; base 405,309,320) | 12 (base 11) | 115.51 s (base 111.08) | 13,413,498 B (≡ base) |

### 2026-08-05 03:10 UTC — Run D: K5 TRUE interning (**+18.3% REGRESSION — reverted**)

Global intern table handing out unique ids (plan §12), run at
`Prune.pruneUnreachableSpecs` so BOTH engines' graphs are interned before
GlobalOpt/codegen; id equality replaces the K4 confirm walk, with a structural
fallback for uninterned types. Same source, equal majors (11=11), identical
output size (12,978,169 B): **4:39.50 vs 3:56.35 = +43.2 s (+18.3%)**, objects
**+221.9M (+56%)**, bytes +5,172 MB. Cause is structural, not tuning:
retrofitting ids onto an already-built graph means REBUILDING every type in it
(Elm values are immutable), which dwarfs confirm walks that the profile capped
at ≤1.94% of runtime total. Conclusion: interning must happen at CONSTRUCTION
or not at all — and that is the multi-day both-engine cascade (§12).
**REVERTED**; the tree carries Run C's state.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **4:39.50** (K4+fix ref 3:56.35) | — | 616,215,747 | 23,860.96 MB | — | — | 11 (=ref) | — | 12,978,169 B |

### 2026-08-05 00:40 UTC — Run C: mono comparable-key K4 interning (**alloc −1.2% TRUE, wall FLAT**)

`plans/mono-comparable-key-optimization.md` K4: `MonoType`'s five composite
constructors carry a packed structural hash (`layoutHash * 2^26 + specHash`)
built by smart constructors in O(arity); every layout- and spec-intent
dictionary keys on that hash via a new bucketed `Data.HashMap`, so no
comparable STRING is built for a dictionary operation any more (0
`toComparableLayoutKey` call sites remain). **Output is NOT byte-identical by
design** — iteration order changed — but it is the same SIZE (12,953,038 B
both), the signature of a pure permutation of spec indices / type ids.
Same-source interleaved vs the K1+K2 binary: **3:48.71 vs 3:49.51 = −0.80 s
(−0.35%)** after the bucket-churn fix below (before it: 3:49.09 vs 3:49.17 =
flat), equal majors (10=10), objects PROMOTED identical (375.9M).
**The standard binary's counter read −13.5% objects / −21.3% bytes and is
WRONG — the inline-alloc caveat above, which has now misread two consecutive
runs.** Census legs (`ECO_INLINE_ALLOC=0`, same source, both binaries) give
the true figure: **objects −66.7M (−1.67%), bytes −2,048 MiB (−1.31%)** —
`Cons −149.0M (−27.1%)` and `StringRope −9.3M (−96.7%)` for the deleted
fragment lists and key strings, against **`Tuple2 +88.5M`** and `Int +7.5M`
(boxed hashes). A follow-up pass removed the `Data.HashMap` pair churn
(`replaceInBucket` no longer returns `( bucket, added )` per step; `foldl` and
`values` no longer materialise `( k, v )`), worth **−11.2M objects / −286 MiB**
— which also PROVES bucket churn was never the bulk of that `Tuple2` pool; its
remaining source is unattributed (`sortBy` is native and does not decorate).
Gates: elm-tests 13,058/12 known, E2E 1619/1619, bootstrap green incl. BOTH
fixed points. One real bug found and fixed: hash-ordered iteration broke a
multi-specialization emission path (`eco.papCreate` out-of-scope SSA ref) —
`Data.HashMap` iteration is now INSERTION-ordered.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:48.71** (pre-K4 ref 3:49.51; pre-fix 3:49.09/3:49.17) | 6,085,980 kB | 393,315,712 | 18,633.70 MB | 875 | 376,204,729 (95.6%) | 10 (=pre-K4) | 85.76 s | 12,953,038 B |

### 2026-08-04 22:55 UTC — Run B: mono comparable-key K1+K2 (−1.2% wall, −2.7 GB alloc; byte-identical)

`plans/mono-comparable-key-optimization.md` K1 (call-site amplifiers) + K2
(work-stack helper → direct forward-building recursion). CATEGORY A: compiler
source only, no pass changes. **Raw wall vs Run A is +2.6 s — that is DAY
DRIFT**; the same-source interleaved pairs settle it: **new 3:45.45/3:44.55 vs
old-binary 3:48.46/3:47.08 = −3.01 s/−2.53 s (−1.3%/−1.1%)**, equal majors
(11=11) in both pairs. Byte-identity old≡new PASS ×3 (both pairs + census).
Census legs (`ECO_INLINE_ALLOC=0`, identical workload): **bytes −2,706 MiB
(−1.74%)**, objects +8.7M (+0.22%) — `Custom −61.6M` (the deleted `WorkItem`
pool), `Tuple2 −10.2M` (`Dict.toList` pairs), `ListBacking −10.1M/−2,973 MiB`
and `ConsChunk −28.1M` (the deleted `List.reverse`, a chunk-producing
combinator), against `Cons +116.7M` — forward `::` building trades few large
chunk backings for many small cells. Encoder is still the #1 cons site
(158.3M). Gates: JS fixed point, elm-tests (12 known pre-existing fails), E2E
**1619/1619**. Baseline census binary segfaults at exit before its tally
(twice; totals unaffected).

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:45.45** (pair2 3:44.55; old-binary 3:48.46/3:47.08) | 6,035,488 kB | 536,483,145 | 22,372.66 MB | 864 | 361,984,931 (67.5%) | 11 (=old) | 85.35 s | 12,898,536 B |

### 2026-08-04 21:40 UTC — Run A: tier-2 baseline (no track opts)

Baseline of the track. Binary = `eco-compiler-borrowopt` built 2026-08-04
per Phase 1 (solver+LSS+borrow build env; all six tier-1 flags default-on
in this source; `list.chunks` hybrid spines default-ON — **no** tier-2
track optimizations yet). Workload = subst, cold eco-stuff, both legs;
warmup leg wall 3:46.27, measured leg reported. NOT comparable with the
tier-1 file's runs: chunked lists shipped since (objects ~802M → ~454M,
matching the L1 hybrid-spines prediction) and the workload moved
(out.mlir 12,925,267 → 12,900,915 B).

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:42.84** (warmup 3:46.27) | 6,017,548 kB | 454,405,404 | 23,471.22 MB | 875 | 361,830,073 (79.6%) | 10 | 82.28 s | 12,900,915 B |

---

## Summary

| run | wall (measured leg) | total heap allocation |
|---|---|---|
| A — tier-2 baseline (no track opts) | 3:42.84 | 454,405,404 obj / 23,471.22 MB |
| B — mono-key K1+K2, **−1.2% vs old binary** (same-source pairs; raw wall is day drift) | 3:45.45 | 536,483,145 obj / 22,372.66 MB |
| D — K5 true interning (post-hoc graph pass), **+18.3% REGRESSION, reverted** | 4:39.50 | 616,215,747 obj / 23,860.96 MB |
| C — mono-key K4 interning + bucket-churn fix, **wall −0.35% (≈flat); TRUE alloc −1.31% bytes** (census; the standard counter's −21.3% is inline-alloc-blind) | 3:48.71 | 393,315,712 obj / 18,633.70 MB (census: 3,933,552,762 / 154,614 MiB) |
| E — K6 construction-time hash-consing, **subst −2.17% wall / −6.15% promotion / −16.4% max RSS; solver +0.93% (one extra major)** | 3:46.33 subst (5:40.54 solver) | 375,458,591 obj / 18,234.64 MB (solver: 576,877,132 / 46,106.28 MB) |
| F — K6 extended to the SOLVER engine, **solver −5.07% wall / −7.04% promotion / −13.2% max RSS / majors 13→10; subst flat (+0.98%, within same-binary spread)** | 5:33.80 solver (3:45.56 subst) | 578,903,113 obj / 46,263.44 MB (subst: 376,270,422 / 18,293.01 MB) |
| G — K7 read-only interning for the `Disabled` callers, **subst −2.0% wall / −2.5% promotion / majors 10→9 (coverage 42.04% → 0.15% disabled at a 98.06% hit rate); solver unaffected by construction and measured flat** | 3:41.83 subst (5:43.01 solver) | 376,384,280 obj / 18,298.94 MB (solver: 579,055,820 / 46,273.95 MB) |
