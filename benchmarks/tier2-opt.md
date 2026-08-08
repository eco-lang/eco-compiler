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
run: label, wall time, total heap allocation. Numbers are for the leg
**with the run's optimization applied** only; baseline, A/B, and flavor
numbers belong in the run entries. Just the table, no write-up.

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

### 2026-08-08 11:40 UTC — Run L: no_caller_saved_registers + call-free eco_bump_state (**FLAT; NCSR machinery reverted, call-free body + constinit TLS KEPT**)

Run K's return-safe successor (`plans/preserve-cc-runtime-helpers.md`
§residual (a)+(c)): `eco_bump_state` body made CALL-FREE (inline TLS read;
6 instructions; required BOTH `constinit` — kills the cross-TU C++
TLS-init guard — AND `tls_model("initial-exec")` — kills the
`__tls_get_addr` call the -fPIC EcoRuntimeStatic compile emits; NCSR's
save-set is decided at compile time even though the linker relaxes the
call away). Arms: ncsr0 = call-free body, ccc callers; ncsr1 = + LLVM-side
`no_caller_saved_registers` on 74,659 generated call sites. Return-value
mechanics microtest-verified (rax excluded from saves — the thing Run K's
CCs get wrong); text −438,920 B (−0.78%); 22 min of legs, zero faults;
out.mlir byte-identical ncsr0≡ncsr1. **Interleaved pairs SPLIT: r1 −1.40 s
(−0.63%), r2 +0.59 s (+0.27%) ⇒ FLAT** (majors 10≡10, GC stats
identical). Int-heavy workload ⇒ xmm-relief structurally untestable.
Verdict: mechanism proven, no wall win ⇒ NCSR flag+fixup REVERTED;
call-free body + constinit/tls_model kept (strict improvements). Raw
~−4 s vs Run K cc0 is cross-day — NOT claimable (day-drift lesson).

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| ncsr0 m1 | **3:41.71** (warm 3:44.15) | 5,123,640 kB | 380,045,113 | 18,549.76 MB | 871 | 372,544,401 (98.0%) | 10 | 84.76 s | 12,955,155 B |
| ncsr1 m1 | **3:40.31** (warm 3:41.28) | 5,122,776 kB | 380,045,113 | 18,549.76 MB | 871 | 372,544,401 (98.0%) | 10 | 82.99 s | 12,955,155 B (≡ ncsr0) |
| ncsr0 m2 | 3:39.74 | 5,123,796 kB | 380,045,113 | 18,549.76 MB | 871 | 372,544,401 | 10 | 83.58 s | 12,955,155 B |
| ncsr1 m2 | 3:40.33 | 5,122,916 kB | 380,045,113 | 18,549.76 MB | 871 | 372,544,401 | 10 | 83.15 s | 12,955,155 B |

### 2026-08-08 00:05 UTC — Run K: preserve_most/preserve_all on GC runtime helpers (**FATAL: x86-64 preserve CCs clobber return values ⇒ both arms SIGSEGV; REVERTED**)

`plans/preserve-cc-runtime-helpers.md`, three arms from one methodology:
cc0 = untouched HEAD; cc1 = Step 1 (`ECO_PRESERVE_CC=1`: preserve_all
`eco_bump_state` + preserve_most on 5 gc-leaf helpers; 6 funcs / 223,286
call sites retagged, text −2.16 MB); cc2 = Step 2 (+ preserve_all
`eco_alloc_inline_slow`/`eco_list_tail_hybrid`; 8 funcs / 302,363 sites).
**cc1 AND cc2 SIGSEGV at 0.09 s** (first CAF, `Pretty_tightline`'s bump
diamond reads `(%rax)` = 0): LLVM's x86-64 CSR sets for preserve_most/all
include RAX — callee epilogue `pop %rax` DESTROYS the return value (asm-
verified), so the conventions cannot carry returns on x86-64 (AArch64
excludes X0–X8). Every primary target returns a value ⇒ plan unimplementable
as designed; fully REVERTED. Bonus autopsy: helpers with non-inlined inner
calls save 8 GPR + 16 xmm (bump_state) / 14 GPRs (scratch_push_boxed) per
call — the "tiny callee ⇒ free" premise fails as compiled anyway. out.mlir
12,955,155 B ≠ Run J (workload moved since); cc0 walls not J-comparable.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| cc0 baseline | **3:45.03** (warmup 3:44.14) | 5,155,212 kB | 380,045,107 | 18,549.76 MB | 871 | 372,544,400 (98.0%) | 10 | 83.61 s | 12,955,155 B |
| cc1 Step 1 | **SIGSEGV @ 0.09 s** | — | — | — | — | — | — | — | — |
| cc2 Step 2 | **SIGSEGV @ 0.09 s** | — | — | — | — | — | — | — | — |

### 2026-08-06 00:15 UTC — Run J: promotion-time list chunking (**P1 mean run = 1.69 ⇒ NO-GO; +5.7% wall when ON; REVERTED**)

`plans/promotion-time-list-chunking.md` implemented (HEAP_041), measured;
RECORDS the plan's own §5 P1/D-PC gate numbers. Same binary all legs,
flavors = `ECO_PROMO_CHUNK` 0/1/2, interleaved pairs, byte-identity 0≡1≡2
PASS. **P1: mean promotable run 1.69 (73% singletons; the gate wanted ≥8);
only 11.2% of promoted Cons in chunkable runs. Mode 2 cost +12.6 s (+5.7%)
wall — majors 9→11, +2.14M mutator view allocs — for −3.1% promotion /
−1.2% RSS; the mode-1 peek alone +1.8%.** Lazy views 704; self-checks
EXACT; gates green (unit+E2E 1627/1627, ECO_HEAP_VALIDATE). Verdict NO-GO
→ fully REVERTED 2026-08-06; the latent validate-walker zero-stride fix
it uncovered was re-landed standalone the same day, with a regression test.

| leg | wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|---|
| m0 off | **3:41.79** (r2 3:42.00) | 5,176,764 kB | 376,384,274 | 18,298.94 MB | 848 | 357,488,231 (95.0%) | 9 | 82.63 s | 12,959,381 B (≡ Run G) |
| m1 measure | 3:45.33 (r2 3:46.45) | 5,176,836 kB | 376,384,274 | 18,298.94 MB | 848 | 357,488,231 (=m0) | 9 (=m0) | 84.53 s | 12,959,381 B (≡ m0) |
| m2 on | 3:54.64 (r2 3:54.16; warmup 3:57.38) | 5,114,772 kB | 378,528,424 | 18,364.39 MB | 848 | **346,471,007** (91.5%) | **11** | 92.37 s | 12,959,381 B (≡ m0) |

### 2026-08-05 22:20 UTC — Run I: W1 Custom arity census (**re-aims sum-type-wrapper-unboxing**)

`plans/sum-type-wrapper-unboxing.md` W1 dynamic half: `Custom`'s
`Header.size` IS the field count, so the LH1 promotion histogram splits by
arity for free; `nfields==1` is an exact UPPER BOUND on the payload-unboxing
target. **Result: 1-field is only 12.2%/13.8% of promoted Custom = 7.4% of
total promotion; 2-field DOMINATES at 56.2%/52.5% and is not addressable.
Surprise: 0-field = 19.7M/23.8M promoted objects carrying ZERO data
(9.1%/10.0%, 301 MiB)** — nullary ctors that allocate only because their
union has a non-nullary arm. **Re-aims the plan onto option (a) generalized
nullary embedding**: near-equal population, total per-object win, simpler
mechanism. Walls not comparable (no warmup leg — composition run).

| leg | wall | objects alloc'd | promoted | promoted Custom | 0-field | 1-field | 2-field |
|---|---|---|---|---|---|---|---|
| subst | 3:48.29 | 376,384,275 | 357,488,231 | 216,982,024 | 19,727,577 (9.1%) | 26,374,254 (12.2%) | **121,871,271 (56.2%)** |
| solver | 5:49.89 | 579,055,813 | 385,666,258 | 238,406,822 | 23,839,766 (10.0%) | 32,952,581 (13.8%) | **125,064,224 (52.5%)** |

### 2026-08-05 21:41 UTC — Run H: LH1 per-kind retention histogram (**instrumentation only; the ranking result**)

`plans/live-heap-composition-census.md` LH1: per-tag promotion/survival
histograms in `GCStats`, recorded inside the collector at the six
evacuation sites (`NurserySpace.cpp`) — so exact in the standard binary,
unlike the allocation histogram. Self-check passes on both engines
(histogram total ≡ `objects_promoted`, zero out-of-range tags); walls and
`out.mlir` match Run G, so overhead is nil and the workload unmoved.
**Result: promotion = `Custom` 60.7%/61.8% + `Cons` 36.7%/34.7% =
97.4%/96.5% of retention** (subst/solver); `Closure` 0.002% against ~22% of
true allocation; `Tuple2` 0.6% against ~19%. **Allocation ranking and
retention ranking are nearly disjoint.** D-LH gates: both PASS (6×/7×).

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:46.03** subst (warmup 3:48.10; Run G base 3:46.84) | 5,178,596 kB | 376,384,275 | 18,298.94 MB | 848 | **357,488,231** (10,233 MiB) | 10 | 84.71 s | 12,959,381 B (≡ Run G) |
| **5:43.46** solver (Run G base 5:43.01) | 5,389,204 kB | 579,055,813 | 46,273.95 MB | 1422 | **385,666,258** (11,226 MiB) | 12 | 113.02 s | 13,415,623 B (≡ Run G) |

**Promoted-set composition (the LH1 deliverable):**

| kind | subst promoted | % of promo | bytes | solver promoted | % of promo |
|---|---|---|---|---|---|
| `Custom` | 216,982,024 | **60.7%** | 6,794 MiB | 238,406,822 | **61.8%** |
| `Cons` | 131,038,610 | **36.7%** | 2,999 MiB | 133,991,816 | **34.7%** |
| `Record` | 4,496,356 | 1.3% | 211 MiB | 7,500,065 | 1.9% |
| `Tuple2` | 2,215,169 | 0.6% | 51 MiB | 2,298,306 | 0.6% |
| `StringUtf8Leaf` | 1,786,437 | 0.5% | 62 MiB | 1,975,084 | 0.5% |
| `Array` | 352,317 | 0.1% | 89 MiB | 734,821 | 0.2% |
| `ConsChunk`+`ListBacking` | 192,494 | 0.05% | 9 MiB | 217,682 | 0.06% |
| `Closure` | **7,861** | **0.002%** | 415 KiB | (below cut) | — |

### 2026-08-05 19:30 UTC — Run G: K7 read-only interning for the `Disabled` callers (**subst −2.0% wall, −2.5% promotion, majors 10→9; solver unaffected**)

`plans/mono-comparable-key-optimization.md` K7 §16: `Intern` gains a
`ReadOnly` mode that probes but never inserts, so read-only traversals need
no state threading — `applySubstPureRO` wraps the existing recursion;
`Specialize`'s 16 sites and `unifyCallSiteDirect*`'s 4 lend `accum.intern`.
Census: composite `hashCons` arriving `Disabled` 42.04% → 0.15%, probe hit
98.06%. Subst pairs **−4.21/−5.01 s (−1.85%/−2.21%)** at −9.26M promoted
(−2.52%); GC time covers 73%/70% of it, RSS flat. **The solver never calls
`TypeSubst`** and measures flat (wall ±1% both ways, promotion =, majors
12=12). `.mlir` byte-identical under BOTH engines. Gates: elm-tests
13,063/12 known, E2E 1619/1619, bootstrap EXIT=0 (both fixed points).

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:41.83** subst (base 3:46.84; r1 3:43.26/3:47.47) | 5,176,332 kB (base 5,178,332) | 376,384,280 (base 376,387,209) | 18,298.94 MB (base 18,299.04) | 848 (base 850) | **357,488,232** (95.0%; base 366,746,517) | **9** (base 10) | 81.40 s (base 84.92) | 12,959,381 B (≡ base) |
| **5:43.01** solver (base 5:46.15; r1 5:42.93/5:39.38) | 5,386,172 kB (base 5,389,976) | 579,055,820 (base 579,055,819) | 46,273.95 MB (base 46,273.95) | 1422 (=base) | 385,666,259 (66.6%; =base) | 12 (=base) | 111.92 s (base 113.35) | 13,415,623 B (≡ base) |

### 2026-08-05 16:00 UTC — Run F: K6 on the SOLVER engine (**solver −5.07% wall, −7.04% promotion, −13.2% RSS, 3 fewer majors**)

`plans/mono-comparable-key-optimization.md` §15: the K6 `Intern` table
threaded through the solver's own producers (`Store.classifyGo`,
`zonkToMono`'s `ZonkCtx`, `canTypeToMonoWithI`, `cachedSchemeMono`,
`Intern.widenSets`); table home = new `S.intern` (M2 memos grouped to fit
the 32-slot record cap). Output byte-identical to both baselines under both
engines. Interleaved triples: **solver −17.81 s (−5.07%), promotion −29.2M
(−7.04%), max RSS −13.15%, majors 13→10**, GC −16.28 s = 91% of the wall
delta; objects +0.02% — a pure RETENTION win. **Subst flat** (+0.98%,
within same-binary spread). Gates: elm-tests 13,061/12, E2E 1619/1619,
bootstrap both fixed points. NOT wall-comparable to Run E (workload moved).

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **5:33.80** solver (k4fix 5:51.61, k6sub 5:54.45; r1 5:36.34/5:53.48/5:51.99) | 5,599,448 kB (k4fix 6,447,176; k6sub 6,432,136) | 578,903,113 (k4fix 594,600,469; k6sub 578,762,454) | 46,263.44 MB (k4fix 46,622.70) | 1438 (k4fix 1448) | 385,929,900 (66.7%; k4fix 415,153,413; k6sub 414,784,293) | 10 (k4fix 13; k6sub 13) | 105.92 s (k4fix 122.20; k6sub 124.37) | 13,414,246 B (≡ both) |
| **3:45.56** subst (k4fix 3:58.36, k6sub 3:43.37) | 5,605,656 kB (k6sub 5,594,200) | 376,270,422 (k6sub 376,270,899) | 18,293.01 MB (k6sub 18,293.02) | 866 (=k6sub) | 367,270,883 (97.6%; k6sub 367,132,890) | 9 (=k6sub) | 83.10 s (k6sub 81.97) | 12,958,010 B (≡ both) |

### 2026-08-05 14:00 UTC — Run E: K6 construction-time hash-consing (**subst −2.17% wall, −16.4% RSS; solver flat**)

`plans/mono-comparable-key-optimization.md` K6: an `Intern` table
(`Compiler.AST.Intern`, structure → canonical object, keyed by `specHashOf`,
decided by exact `==`) threaded through `TypeSubst.applySubstPureI` and out
through `applySubstFV`'s 52 `Specialize` call sites, plus an `a == b ||`
fast path on `eqKeySpec`/`eqKeyLayout`. Output byte-identical both engines
— sharing is not observable. Interleaved pairs vs pre-K6: **subst −5.02 s
(−2.17%), promotion −23.5M (−6.15%), max RSS −16.4%**, equal majors, GC
time −5.71 s covers the whole wall delta — the retention mechanism no
allocation count could predict. **Solver +0.53%/+0.93%** (K6 threads only
the subst engine; delta is one extra major). Gates all green, both engines.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:46.33** subst (base 3:51.35; r1 3:47.66/3:52.56) | 5,113,520 kB (base 6,115,016) | 375,458,591 (base 394,063,375) | 18,234.64 MB (base 18,661.13) | 863 (base 879) | 358,646,365 (95.5%; base 382,136,977) | 10 (=base) | 83.60 s (base 89.31) | 12,956,798 B (≡ base) |
| **5:40.54** solver (base 5:37.39; r1 5:39.28/5:37.49) | 7,055,140 kB (base 7,042,752) | 576,877,132 (base 592,663,234) | 46,106.28 MB (base 46,467.59) | 1434 (base 1443) | 405,420,508 (70.3%; base 405,309,320) | 12 (base 11) | 115.51 s (base 111.08) | 13,413,498 B (≡ base) |

### 2026-08-05 03:10 UTC — Run D: K5 TRUE interning (**+18.3% REGRESSION — reverted**)

Global intern table handing out unique ids (plan §12), run at
`Prune.pruneUnreachableSpecs` so BOTH engines' graphs are interned before
GlobalOpt/codegen; id equality replaces the K4 confirm walk. Same source,
equal majors (11=11), identical output size: **4:39.50 vs 3:56.35 =
+43.2 s (+18.3%)**, objects **+221.9M (+56%)**. Cause is structural:
retrofitting ids onto an already-built graph REBUILDS every type in it
(immutability), dwarfing confirm walks the profile capped at ≤1.94% of
runtime. Conclusion: interning must happen at CONSTRUCTION or not at all
(the §12 cascade). **REVERTED**; the tree carries Run C's state.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **4:39.50** (K4+fix ref 3:56.35) | — | 616,215,747 | 23,860.96 MB | — | — | 11 (=ref) | — | 12,978,169 B |

### 2026-08-05 00:40 UTC — Run C: mono comparable-key K4 interning (**alloc −1.2% TRUE, wall FLAT**)

`plans/mono-comparable-key-optimization.md` K4: `MonoType`'s five composite
constructors carry a packed structural hash built by smart constructors in
O(arity); every layout-/spec-intent dictionary keys on it via a new
bucketed `Data.HashMap` — 0 `toComparableLayoutKey` call sites remain.
Output NOT byte-identical by design (iteration order) but same SIZE — a
pure permutation. Interleaved vs K1+K2: **−0.80 s (−0.35%) ≈ FLAT** (incl.
a follow-up HashMap pair-churn fix worth −11.2M obj), equal majors,
promotion identical. **The standard counter's −21.3% bytes is WRONG
(inline-alloc blind); census truth: objects −1.67%, bytes −1.31%** (Cons
−27.1%, Tuple2 +88.5M). Bug fixed: hash-ordered iteration broke codegen →
`Data.HashMap` is now INSERTION-ordered. Gates all green.

| wall | max RSS | objects alloc'd | bytes alloc'd | minor GC | promoted | major GC | GC time | out.mlir |
|---|---|---|---|---|---|---|---|---|
| **3:48.71** (pre-K4 ref 3:49.51; pre-fix 3:49.09/3:49.17) | 6,085,980 kB | 393,315,712 | 18,633.70 MB | 875 | 376,204,729 (95.6%) | 10 (=pre-K4) | 85.76 s | 12,953,038 B |

### 2026-08-04 22:55 UTC — Run B: mono comparable-key K1+K2 (−1.2% wall, −2.7 GB alloc; byte-identical)

`plans/mono-comparable-key-optimization.md` K1 (call-site amplifiers) + K2
(work-stack helper → direct forward-building recursion); compiler source
only, no pass changes. Raw wall vs Run A is +2.6 s = DAY DRIFT; the
same-source interleaved pairs settle it: **−3.01/−2.53 s (−1.3%/−1.1%)**,
equal majors in both pairs; byte-identity old≡new PASS ×3. Census legs:
**bytes −2,706 MiB (−1.74%)**, objects +0.22% — `Custom −61.6M` (deleted
`WorkItem` pool), `ListBacking −10.1M/−2,973 MiB`, `ConsChunk −28.1M`
(deleted `List.reverse`) against `Cons +116.7M` — forward `::` trades few
large chunk backings for many small cells. Encoder still the #1 cons site
(158.3M). Gates: JS fixed point, elm-tests (12 known fails), E2E 1619/1619.

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
| A — tier-2 baseline | 3:42.84 | 454,405,404 obj / 23,471.22 MB |
| B — mono-key K1+K2 | 3:45.45 | 536,483,145 obj / 22,372.66 MB |
| C — mono-key K4 hash keys | 3:48.71 | 393,315,712 obj / 18,633.70 MB |
| D — K5 true interning (reverted) | 4:39.50 | 616,215,747 obj / 23,860.96 MB |
| E — K6 hash-consing (subst) | 3:46.33 | 375,458,591 obj / 18,234.64 MB |
| F — K6 on solver (solver leg) | 5:33.80 | 578,903,113 obj / 46,263.44 MB |
| G — K7 read-only interning (subst) | 3:41.83 | 376,384,280 obj / 18,298.94 MB |
| H — LH1 retention census (subst) | 3:46.03 | 376,384,275 obj / 18,298.94 MB |
| I — W1 Custom arity census (subst) | 3:48.29 | 376,384,275 obj / 18,298.94 MB |
| J — promo-time chunking, mode 2 (reverted) | 3:54.64 | 378,528,424 obj / 18,364.39 MB |
| K — preserve-cc GC helpers (SIGSEGV ×2, reverted) | crash @ 0.09 s (base 3:45.03) | n/a (base 380,045,107 obj / 18,549.76 MB) |
| L — NCSR + call-free bump_state (flat; NCSR reverted, body kept) | 3:40.31 (ncsr0 3:41.71) | 380,045,113 obj / 18,549.76 MB |
