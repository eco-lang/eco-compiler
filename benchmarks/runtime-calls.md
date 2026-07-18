# Runtime Call Stats — Stage-7a Dynamic-Dispatch Census

Tracks the **dynamic closure-dispatch** the compiler executes while self-compiling,
via the `ECO_DISPATCH_STATS` runtime census (LSS dispatch-value plan E0,
`plans/lss-dispatch-value-extraction.md`). "Dynamic dispatch" = an indirect call
through a closure's `evaluator` pointer — the population LSS singleton/small-set
stamping would convert to direct calls. Append one timestamped section per run.

---

## Methodology (repeat exactly each time)

**Workload — cold-cache Stage 7a.** The native `eco-compiler` front-end compiling
the entire compiler front-end (`compiler/src/Terminal/Main.elm`, ~243 modules) to
MLIR. This is the standard bootstrap benchmark; the compiled program *is* the
compiler, so the dispatch stats are the compiler's own runtime behavior.

**Binary.** `build/compiler/build-kernel/bin/eco-compiler`, `build` preset
(RelWithDebInfo, asserts + GC-stats ON → single-threaded, ~2.6× slower than a
release build but deterministic — the standard bootstrap config).

**Two independent engine knobs.** A benchmark has TWO separate engine choices, and
they must not be confused — that is exactly what the table's `X-built / Y` labels
mean:

  - **Build engine** — how the `eco-compiler` *binary itself* is compiled (its own
    codegen: subst vs solver+LSS). Set by the env at the `cmake --build` step.
  - **Workload engine** — how that binary *monomorphizes when it runs* (compiling
    the source it is fed). Set by the env at the `make` run.

`solver-built / subst` = a binary compiled under solver, then run under subst; etc.
Both default to `subst` when `ECO_MONO_ENGINE` is unset (`solver` additionally
exercises LSS stamps / the `fast` counter; `ECO_MONO_LSS=1` turns lambda-set
specialization on under solver).

**Cache reset — delete `eco-stuff/`, do NOT touch sources.** The project build cache
lives at `build/compiler/build-kernel/eco-stuff/` (holds the per-package typed
artifacts, keyed by a `Config.hash` that folds in the engine). The clean, honest way
to force a full cold recompile is to **`rm -rf` the whole `eco-stuff/` directory** —
not to `touch` source files. (Touching only bumps mtimes and is fragile; a real
source edit already bumps mtime and ninja rebuilds naturally, so touching is never
needed.) A source edit rebuilds the guida→eco-boot bootstrap chain automatically; an
*engine* change with no source edit is invisible to mtime, so `eco-stuff/` deletion
is the reset that matters. `eco-stuff-subst/` is a dormant leftover — ignore it.

**Census.** `ECO_DISPATCH_STATS=1`. Counters (per evaluator fp, dumped to stderr at
exit): `sat` = saturated indirect evaluator calls (the dispatch total); `gen` = the
subset routed through the generic/unknown-saturation funnel; `typed = sat − gen` =
the statically-known-arity path (`emitInlineClosureCall`); `fast` = statically
stamped direct `$cap` calls (LSS coverage — requires lowering the binary with
`ECO_LSS_DISPATCH_SITE_COUNTERS=1`, wired 2026-07-16 (E0.4)). Sanity invariant:
`gen ≤ sat`. The LSS mono-time census (analysis side: `dispatchUpgraded`,
`stampedPapPrefix`, `declinedShape …`) is printed to stderr by `ECO_MONO_LSS_REPORT=1`.

**Testing is a separate pass — do NOT run test gates while benchmarking.** Assume the
elm-tests + E2E corpus gates pass; correctness is validated in dedicated test passes
(and, for any LSS-set change, the compiler self-compile is the real gate). Mixing
gate runs into a benchmark only pollutes timings and the `eco-stuff/` cache.

**Commands** (run from `/work`).

*Phase 1 — build a binary of a chosen flavor.* Wipe the cache, set the BUILD engine,
build, then preserve the binary under a flavor-labelled name:

```bash
BK=build/compiler/build-kernel
# (only after a runtime/RuntimeExports.cpp change: rebuild + force-relink the runtime,
#  which the CMake dep graph does not auto-relink against eco-compiler)
# cmake --build build --target EcoRuntimeStatic && rm -f "$BK/bin/eco-compiler"

rm -rf "$BK/eco-stuff"                                  # clean cache → full cold build
# BUILD engine below (omit both env vars = subst):
ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 \
    cmake --build build --target eco-compiler
cp -p "$BK/bin/eco-compiler" "$BK/bin/eco-compiler-solver"   # label the flavor; preserve
```

*Phase 2 — benchmark that binary self-compiling to MLIR.* Wipe the cache AGAIN, then
run the labelled binary compiling the whole front-end, with the WORKLOAD engine +
census + timing:

```bash
rm -rf "$BK/eco-stuff"                                  # clean cache again → cold self-compile
# WORKLOAD engine (ECO_MONO_ENGINE/ECO_MONO_LSS) is independent of the build engine:
( cd "$BK" && ulimit -c 0 && \
    ECO_MONO_ENGINE=solver ECO_MONO_LSS=1 \
    ECO_MONO_LSS_REPORT=1 ECO_DISPATCH_STATS=1 \
    /usr/bin/time -v -o timing.txt \
    ./bin/eco-compiler-solver make --optimize --kernel-package eco/compiler \
        --local-package eco/kernel=/work/eco-kernel-cpp \
        --output=bin/out.mlir /work/compiler/src/Terminal/Main.elm  2> census.log )

# Symbolize the top-N evaluators (runtime dispatch census):
benchmarks/dispatch-census.sh "$BK/bin/eco-compiler-solver" "$BK/census.log" 25
```

For an A/B of two binaries (e.g. baseline vs a change), run Phase 2 for each against
the **same** input source tree; `cmp` the two `out.mlir` (byte-identical ⇒ the change
is codegen-neutral) and diff the two `census.log`.

**Runs & reporting.** The dispatch **counts are deterministic** — a single-threaded,
deterministic compile produces byte-identical stats every time (verified 2026-07-16:
`sat`/`gen`/`typed` identical across 3 runs). So **one run is sufficient** for the
call stats; there is no need to repeat for the numbers. Only bother with extra runs
if you also want a stable *wall-clock* figure — then do one throwaway run first to
warm the page cache and report the second. Wall-clock is **census-on** (per-dispatch
atomic increments inflate it vs the clean ~277 s baseline) — keep it census-on for
repeatability. Never delete `~/.eco` (warm package cache). Non-perturbation check:
the output `eco-compiler-boot.mlir` must be byte-identical to the known-good size
for that engine and front-end generation (subst: 12,007,395 B pre-E2;
**12,013,389 B** for the E2 + cross-stage-fix front-end, 2026-07-17).

---

## Runs

### 2026-07-16 18:10 UTC — baseline, subst engine (Run A)

First baseline of dynamic dispatch on the shipping (subst) compiler. Establishes
the total LSS-convertible dispatch population and its top sites.

```
sat=922,254,519  gen=904,422,264  typed=17,832,255  fast=0  distinct=5,990  overflow=0
```

- **922.3 M dynamic dispatches** total. Generic funnel = **98.07 %**; statically-
  known typed path = **1.93 %** (17.8 M). `fast=0` as expected (subst has no LSS
  stamps). 5,990 distinct evaluators, no table overflow.
- Deterministic: `sat`/`gen`/`typed` identical across all 3 runs. Output MLIR
  12,007,395 B every run = the known-good subst size → instrumentation does not
  perturb the compiler.
- Wall (census-on): 4:38.9 / 4:40.9 / 4:37.5 (runs 1/2/3); RSS ≈ 4.65 GB.
- **Concentration** (top evaluators, `sat`):

  | sat (M) | share | evaluator |
  |--:|--:|---|
  | 139.1 | 15.1 % | `List.cons` (as a HOF value in folds/maps) |
  | 33.9 | 3.7 % | `Terminal_Main_lambda_8274` — TypeCheck.IO bind continuation |
  | 20.6 | 2.2 % | `Terminal_Main_lambda_8290` — IO continuation |
  | 18.2 | 2.0 % | `Terminal_Main_lambda_8268` — IO continuation |
  | 17.8 | 1.9 % | `Terminal_Main_lambda_8286` — IO continuation |
  | 11.8 | 1.3 % | `List.cons` (second monomorphization) |
  | 10.2 | 1.1 % | `Terminal_Main_lambda_8179` / `_8190` — IO continuations |
  | 9.5 | 1.0 % | `accessor_name` value / `lambda_26662` |
  | 6.7–8.7 | ~0.8 % ea | `Maybe.map`, `IO.traverseList`, `TypeSubst.applySubstPure`, `AST.Canonical` walkers, more IO continuations |

  The head is dominated by `List.cons`-as-HOF and the TypeCheck.IO monadic-bind
  continuations (the same lambdas that top the *allocation* census). These are the
  dispatch the E-track wants to eliminate — but Run B shows the current singleton
  stamp does **not** reach them. A few rows resolve to nearby library symbols
  because their real evaluator symbol is static/stripped — a symbolization
  artifact, the counts are real.

Raw logs: `$CLAUDE_JOB_DIR/tmp/census.{1,2,3}.log` (transient); reproduce via the
commands above.

### 2026-07-16 19:35 UTC — Run B: solver+LSS-built binary (fast coverage)

Populates `fast` = current LSS coverage. A compiler whose OWN code carries LSS
singleton stamps, built with the stamp counter (E0.4) on. Build recipe (repeatable):

```bash
BK=build/compiler/build-kernel
# 1. front-end under solver -> LSS-stamped MLIR (12,066,630 B):
( cd "$BK" && rm -rf eco-stuff && ECO_MONO_ENGINE=solver ./bin/eco-compiler make \
    --optimize --kernel-package eco/compiler --local-package eco/kernel=/work/eco-kernel-cpp \
    --output=bin/eco-compiler-solver.mlir /work/compiler/src/Terminal/Main.elm )
# 2. lower WITH the fast-counter emission on (E0.4 fires at stamped sites):
ECO_LSS_DISPATCH_SITE_COUNTERS=1 build/runtime/src/codegen/eco-boot-native \
    "$BK/bin/eco-compiler-solver.mlir" -o "$BK/bin/eco-compiler-solver"
# 3. census the resulting binary (ECO_MONO_ENGINE = the workload's engine):
( cd "$BK" && rm -rf eco-stuff && ECO_MONO_ENGINE=subst ECO_DISPATCH_STATS=1 \
    ./bin/eco-compiler-solver make --optimize --kernel-package eco/compiler \
    --local-package eco/kernel=/work/eco-kernel-cpp --output=bin/eco-compiler-boot.mlir \
    /work/compiler/src/Terminal/Main.elm 2> census.log )
```

Same binary, two workloads:

- **subst runtime** (same workload as Run A):
  `sat=905,674,857  gen=887,841,978  typed=17,832,879  fast=16,115,982  distinct=6,006`.
  **LSS coverage = fast/(sat+fast) = 1.75 %.** `sat+fast` = 921.8 M ≈ Run A's 922.3 M
  (same workload — the 16.1 M fast slice came out of `gen`, which dropped ~16.6 M;
  `typed` unchanged). Output 12,007,395 B = Run A's subst size → the solver-built
  binary is a correct compiler. Wall 4:31.
- **solver runtime** (the full solver+LSS world):
  `sat=1,779,261,015  gen=1,761,633,971  typed=17,627,044  fast=64,955,590  distinct=6,581`.
  **LSS coverage = 3.52 %.** The solver monomorphizer dispatches ~2× as much (1.78 B)
  and 4× the fast (65 M). Output 12,066,630 B = solver size. Wall 10:00.

**Key finding — coverage is low because stamped ≠ hot.** The top-20 evaluators by
dispatch weight (`List.cons` 15 %, the IO bind continuations, `Basics.identity`) are
ALL `fast=0`; the closures that *did* stamp (top: `lambda_9032` 3.7 M, `lambda_8525`
3.6 M, `lambda_8832` 2.1 M) have `sat=0` — always fast at their sites. Singleton
stamping cleanly captures closures whose identity is statically unique at every call
site, but never reaches the high-frequency HOF-argument / stored-continuation
closures. That gap is exactly the E2 (PAP-shape) / E3 (small-set) / E5–E6 (per-set
fan-out) target population.

### 2026-07-17 07:50 UTC — Run C: E2 + cross-stage-fix front-end (post-E2 benchmark)

Benchmarks the E2 (PAP-suffix stamping) + cross-stage `segmentation_unknown` fix
front-end. The binary was rebuilt through the bootstrap (`--target eco-compiler`),
so its own code was compiled by the new codegen. NOTE the baseline caveat: Run A/B
binaries came from a Jul-10-era Stage-5 MLIR; Run C's from a fresh Stage 5 — the
deltas below include every front-end change since Jul 10, not E2 alone.

- **C1 — subst workload, dispatch + closure censuses:**
  `sat=922,756,871  gen=904,916,613  typed=17,840,258  fast=0  distinct=5,990`
  and `creates=543,656,993  extends=1,121,487`. Both within +0.06 % of the Run A /
  flag-off baselines (the delta ≈ the slightly larger source) — **E2 and the
  cross-stage fix are dispatch- and allocation-count-neutral on the shipping
  configuration**, as predicted. New known-good subst output: **12,013,389 B**.
- **C2a — solver+LSS self-compile report (E2 counters at scale):**
  `dispatchUpgraded=2395  stampedPapPrefix=0  declinedShape=6857
  (arity=6802 [zero=0 under=0 over=6802] bucketMiss=17 layout=37 char=1)`.
  Two findings: **stampedPapPrefix=0 at scale** (E2 dormant pending inner-arrow
  set transport — expected, mechanism-ready), and — new, decisive — **all 6,802
  arity declines are OVER-application** (flat multi-stage calls, where dispatch
  DOES happen via stage chaining), not under-applies. The staged/multi-stage
  stamp (E2's declared v2) is therefore the real remaining singleton-shape
  class, pool = 6,802 sites. Solver output: 12,072,617 B.
- **C2b — coverage leg (solver-built binary, subst workload):**
  `sat=906,166,573  gen=888,325,694  typed=17,840,879  fast=16,126,268` →
  **coverage 1.75 % — unchanged from Run B**, confirming E2 adds no live stamps
  yet.
- **Wall anomaly — A/B'd 2026-07-17, REAL and front-end-attributed (bisection
  pending).** Same day, same backend, same machine, same workload: the Jul-10-era
  front-end MLIR (`bin/ab-subst-1.mlir`) lowered by today's backend runs Stage 7a
  in **4:30.45**; today's front-end runs **6:02–6:08 (×3)** — **+33 % wall**, while
  doing 19 % FEWER dispatches (1,123 M vs 906 M): another proof that counts don't
  govern wall. Exonerated by measurement: the E2 stamp (dormant flag-off), the
  cross-stage fix and H6.2 Layer 1 (papExtend classification of both MLIRs:
  the no-attr class is 7 old / 8 new — negligible and pre-existing; typed sites
  28,699→18,003 is the known F3/merging win), census overhead (repeat runs
  identical), and the machine (the old binary hit 4:30 the same hour). The
  regression accumulated somewhere in the Jul-10→now front-end landings
  (candidates: the unconditional H6.2 layers — first-stage beta split,
  destructure freshening — F3 merging, apR-exclusion/P2-generic-fusion) and was
  MASKED because intervening wall measurements reused stale Jul-10-era Stage-5
  MLIR binaries (the mtime-cache gotcha in a new costume: `--target eco-compiler`
  does not regenerate Stage 5 unless sources are newer than the cached mlir).
  Needs its own bisection (fresh bootstrap per candidate landing). Until then,
  compare walls only within a front-end generation.

### Run D — spine injection (§S), same-input A/B (2026-07-17)

Two-phase clean method (this doc's Methodology): baseline binary
`eco-compiler-solver` (pre-spine) vs `eco-compiler-spine`, each compiling the
SAME source tree, `rm -rf eco-stuff` before every leg, four legs (each
binary × {solver+LSS, subst}).

- **Flag-off byte-identity — CONFIRMED.** `out-baseline-subst.mlir` and
  `out-spine-subst.mlir` are **byte-identical** (`cmp` clean). Spine +
  arity-bound + the `fastPapPrefix` fix touch only the solver/LSS path
  (`Compiler/MonoSolver/*`, lss-gated `indirectResultAnno`, and an
  `annotateCallStaging` copy that is `Nothing`-over-`Nothing` flag-off), so the
  shipping subst engine is provably untouched — now shown empirically on the
  full compiler, not just by construction.
- **Solver census delta — exactly one stamp.** The ONLY difference in the
  GlobalOpt census is **`stampedPapPrefix` 0 → 1**; `dispatchUpgraded=2395`,
  `declinedShape=6857 (arity=6802 over=6802 bucketMiss=17 layout=37 char=1)`,
  `declinedAbiMismatch=2` are all identical. Spine activates precisely one live
  PAP-prefix stamp at self-compile scale (`Round.roundFun`'s directly-applied
  rounding-lambda partial — the one non-let PAP consumer), now emitted as a
  correct BARE fast symbol (was the dangling `$cap` before the fix). This is the
  §S.9 three-link finding made concrete: the common **let-bound** partial shape
  stays LTop at its use sites until **E4a**, so dispatch coverage is unchanged
  (1 stamp of 2395 ≈ 0.04 %).
- **Output size:** solver `12,074,405 → 12,074,430` B (**+25 B**, the single
  extra fast-dispatch site). Subst byte-identical (see above).
- **Wall — neutral.** solver `6:14.25 → 6:14.57` (+0.3 s, noise); subst
  `5:47.15 → 5:46.25` (spine 0.9 s faster, noise — byte-identical output
  confirms it is not real). The absolute ~6:14 is the current front-end
  generation carrying the Run-C +33 % regression; it cancels in the A/B (both
  legs share it), so spine adds **no measurable analysis or mono-time cost**.

*Reading Run D:* spine injection is a pure analysis extension — it propagates
lambda sets one transport link further (call results / let-definitions) with
zero flag-off impact and essentially zero dispatch-coverage change. Its
exploitation payoff is gated on **E4a** (local-multi use transport); the value
here is (a) the analysis is now correct and self-hosting, and (b) it flushed out
two latent bugs — the arity-unbounded over-injection and E2's dropped
`fastPapPrefix` — that any future stamp activation would also have tripped.

### Run E — E4a local-multi use transport, same-input A/B (2026-07-17)

Two-phase clean method, four legs: `eco-compiler-spine` (pre-E4a) vs
`eco-compiler-e4a`, each × {solver+LSS, subst}, same source tree,
`rm -rf eco-stuff` per leg.

- **Mechanism PROVEN live, activation ZERO at self-compile scale.** The unit
  pin proves the full chain fires on the canonical shape (`let g = f 10` →
  use-site singleton → `fastPapPrefix = Just 1`, RED/GREEN-proven), and the
  flag-on corpus runs `HofPapPrefixDispatchTest`'s StampPap'd fast dispatches
  correctly at runtime. But on the compiler's own code the A/B is **completely
  neutral**: solver census IDENTICAL (`stampedPapPrefix=1` both — still only
  Run D's `Round.roundFun` site; `dispatchUpgraded=2397` both), and the solver
  MLIRs are **byte-identical** (12,088,832 B both). Subst legs byte-identical
  as always. Walls within noise (6:06→6:07 solver, 5:54→5:53 subst).
- **Why zero (the sharpened analysis-limit).** A let-bound partial qualifies
  only if the HOF param it peels carries a SINGLETON set. Specs are
  demand-monomorphized per TYPE, so a HOF called from several sites with
  different lambdas at one type carries the JOIN (multi-member/⊤) — never a
  singleton. The fixture qualifies because exactly ONE lambda ever flows in;
  the compiler's own HOFs don't have that property. This is E0.5's
  "coverage is analysis-limited" verdict made precise: **the let-bound-partial
  class needs per-call-site keyed fan-out (E5) to mint singletons; transport
  alone (S + E4a) is now complete and waiting.**
- Dispatch-coverage census leg SKIPPED — byte-identical MLIR lowers to an
  identical binary; the counts cannot differ.
- (Baseline drift note: Run D reported `dispatchUpgraded=2395`; both Run-E legs
  say 2397 because the WORKLOAD grew — the tree now contains the E4a source
  itself. Same-tree A/B keeps this controlled.)

*Reading Run E:* E4a completes the three-link transport chain and is fully
gated + runtime-proven, at zero cost (byte-neutral when inactive). The
self-compile workload contains no naturally-singleton let-bound partials, so
the coverage needle moves only when E5 keyed fan-out (or user code with
single-provenance HOFs) supplies them. Next measurement point: after E5.1/E5.2
on census-chosen targets.

### Run F — E5 selective keyed fan-out (2026-07-17)

Five build legs (`eco-compiler-e4a` vs `eco-compiler-e5`, same tree, clean
`eco-stuff` per leg) + a two-binary dispatch-census A/B. Keyed targets
(plan §10 selection, chain-keyed): `elm/core:List.foldl`, `List.foldr`,
`List.foldrHelper`, `List.map` + `eco/compiler:System.TypeCheck.IO.andThen`
(the over-apply class, included as v2 evidence).

- **Safety: all clean.** Unkeyed solver legs BYTE-IDENTICAL e4a↔e5 (the E5.1
  gate is inert unconfigured); subst legs BYTE-IDENTICAL (flag-off untouched);
  the KEYED self-compile builds and runs correctly (first selective-keying
  outing of the M4 machinery at scale).
- **Keying is FREE at this dose:** mono wall 9:58.80 → 9:52.93 (noise; the
  +28 % figure was ALL-globals keying), output +16,984 B (+0.14 %), binary
  +63 KB.
- **Static census delta (unkeyed → keyed):** `dispatchUpgraded` 2399 → 2409
  (**+10** exact stamps from the List chain); `stampedPapPrefix` 1 → 1;
  `declinedShapeArityOver` 6817 → **6905 (+88)** — the `IO.andThen`
  singletons land in E2's v1-declined staged class exactly as the design
  predicted.
- **Dynamic coverage A/B (both binaries, identical subst workload, cold):**
  `sat=912,460,929 gen=894,476,930 typed=17,983,999 fast=16,241,234` —
  **IDENTICAL TO THE LAST DIGIT** in both; only `distinct` grew 6008 → 6031
  (the keyed spec evaluators exist but redistribute identity, not counts).
  Coverage stays **1.75 %**. The +10 stamped sites executed ZERO times on
  this workload.

*Reading Run F:* the E5 mechanism is proven end-to-end and costs nothing,
but these targets have no v1 dynamic payoff at self-compile scale: the hot
List rows are the CTOR class (`List.cons` — no instance to stamp), the hot
IO rows are the OVER-APPLY class (v1-declined), and lambda-literal List
callers were already H5-loopified. The actionable positive is the +88:
keying demonstrably mints singletons at the staged over-apply sites, so the
combination that can finally convert the hot IO-continuation dispatch is
**E5 keying + E2-v2 staged stamping** — the staged stamp is now the
highest-value open item on the E-track, with ctor instances (the cons class)
second. Re-measure coverage after either lands.

### Run G — E2.7 staged stamping (2026-07-18): **coverage 1.75 % → 5.37 %**

Five build legs (`eco-compiler-e5` vs `eco-compiler-e2v2`, same tree, clean
`eco-stuff` per leg) + the two-binary dynamic census A/B (same subst
workload, cold).

- **Safety: all clean.** Subst legs BYTE-IDENTICAL (flag-off untouched);
  solver+LSS self-compile GREEN first try with the staged stamps live;
  flag-on corpus 1622/1622 incl. the new `StagedFastDispatchTest` runtime
  pin; elm-tests 12997/12 baseline.
- **Static census (unkeyed):** `stampedStaged=344` — over-apply declines
  drop 6,817 → 6,472 (344 stamped + 1 reclassified `declinedAbiMismatch`;
  the accounting closes). `dispatchUpgraded` unchanged at 2,399 (placement
  untouched — the E2.7 emission-gap consult changes WHERE stamps emit, not
  where they are placed). Keyed compose leg: `stampedStaged=379` (+35 —
  E5-minted singletons convert too, as Run F predicted). Output
  +7,708 B; solver mono wall within noise (10:15 → 10:22).
- **Dynamic census A/B (the headline):**
  `e5:   sat=914,788,678  gen=896,753,530  typed=18,035,148  fast=16,279,298`
  `e2v2: sat=881,022,127  gen=862,986,979  typed=18,035,148  fast=50,045,849`
  → **fast +33,766,551 (+207 %), sat −33,766,551 — EXACTLY equal**, the
  1:1 indirect→direct conversion signature. **Coverage 1.75 % → 5.37 %
  (3.1×).** 344 static stamps convert 33.8 M dynamic dispatches — the
  staged sites ARE the hot IO-continuation class, as the E0 census always
  said. Wall 4:46.60 → 4:42.06 (−1.6 %, single run — treat as directional;
  the counts are the deterministic signal). Note the dynamic gain includes
  both the staged stamps AND previously-placed exact stamps recovered by
  the new `CallDirectKnownSegmentation` consult (the 1,571-of-2,397
  emission gap).

*Reading Run G:* E2.7 is the first E-track phase to move the dynamic
needle — 3.1× coverage at essentially zero compile-time cost, with the E5
compose path live (+35 keyed stamps). Remaining headroom in census order:
the ctor class (`List.cons`, needs ctor instances), the residual 6,472
over-apply declines (first-stage layout misses — per-member attribution
would say whether any carry weight), and later-stage chaining (v3). E1.3
(`inlinehint` on the now-50 M `$cap` calls) is now materially interesting.

---

## Summary

Coverage = `fast / (sat + fast)`. "solver-built" = compiler's own code carries LSS
stamps (front-end run under solver, lowered with `ECO_LSS_DISPATCH_SITE_COUNTERS=1`).

| timestamp (UTC) | binary / runtime | sat (dispatch) | gen | typed | fast | coverage | distinct | wall |
|---|---|--:|--:|--:|--:|--:|--:|--:|
| 2026-07-16 18:10 | subst-built / subst (Run A) | 922,254,519 | 904,422,264 | 17,832,255 | 0 | 0 % | 5,990 | 4:38 |
| 2026-07-16 19:35 | solver-built / subst (Run B) | 905,674,857 | 887,841,978 | 17,832,879 | 16,115,982 | 1.75 % | 6,006 | 4:31 |
| 2026-07-16 19:40 | solver-built / solver (Run B) | 1,779,261,015 | 1,761,633,971 | 17,627,044 | 64,955,590 | 3.52 % | 6,581 | 10:00 |
| 2026-07-17 07:50 | E2-built / subst (Run C1) | 922,756,871 | 904,916,613 | 17,840,258 | 0 | 0 % | 5,990 | 6:08* |
| 2026-07-17 08:03 | E2-solver-built / subst (Run C2b) | 906,166,573 | 888,325,694 | 17,840,879 | 16,126,268 | 1.75 % | 6,006 | 6:02* |
| 2026-07-17 21:0x | E5-solver-built UNKEYED / subst (Run F) | 912,460,929 | 894,476,930 | 17,983,999 | 16,241,234 | 1.75 % | 6,008 | — |
| 2026-07-17 21:1x | E5-solver-built KEYED×5 / subst (Run F) | 912,460,929 | 894,476,930 | 17,983,999 | 16,241,234 | 1.75 % | 6,031 | — |
| 2026-07-18 09:5x | pre-v2 (e5) / subst (Run G) | 914,788,678 | 896,753,530 | 18,035,148 | 16,279,298 | 1.75 % | 6,008 | 4:46.60 |
| 2026-07-18 10:0x | **E2.7-built (e2v2) / subst (Run G)** | 881,022,127 | 862,986,979 | 18,035,148 | **50,045,849** | **5.37 %** | 6,008 | 4:42.06 |

*Run-C walls carry an unattributed +30 % vs Run A/B (see the Run C section) — the
counts are the meaningful comparison; treat the walls as provisional.

*Reading it:* Run G's E2.7 staged stamp is the first phase to move the dynamic
needle: **coverage 1.75 % → 5.37 % (3.1×)** — 344 static staged stamps convert
33.8 M dispatches/run (sat drops by EXACTLY the fast gain; 1:1 indirect→direct).
The prior plateau was a CONVERSION ceiling: S+E4a transport and E5 keying were
correct but their sites were cold or v1-declined; the staged over-apply class
(the IO continuations) was where the weight sat.

*Next:* ctor instances for the `List.cons` class (~15 % of dispatch, the biggest
remaining row), per-member attribution over the residual 6,472 over-apply
declines, later-stage chaining (v3), and E1.3 (`inlinehint` on the now-50 M
`$cap` calls — materially interesting at this coverage).
