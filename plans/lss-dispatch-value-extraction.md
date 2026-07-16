# LSS Dispatch Value Extraction

**Status:** v2 (2026-07-16) — implementation-ready refinement of the v1 outline.
Phases E0/E1/E2/A1 are specified to step level; E3/E5 to step level with an explicit
design-settling step first; E4/E6/E7/E8 remain gated outlines with their design
questions named. Line anchors were verified 2026-07-16; treat them as "near here",
re-grep before editing.
**Input:** `/work/lss-exploitation-opportunities-report.md` (survey);
`design_docs/monomorphization/lambda-set-specialization-design.md` (v1.1);
`plans/lss-lambda-set-specialization.md` (M1–M4 done);
`plans/hof-elimination-closure-alloc-reduction.md` (H0–H7 done; H6.3 V1–V3 absorbed here).
**Goal:** Extract measurable wall-clock benefit from the LSS analysis by building the
exploitation side v1 deferred — and decouple that benefit from the solver engine's
cost so it can ship on the default (subst) pipeline.

---

## 1. Doctrine (unchanged from v1, condensed)

1. **Metric = dispatch events + wall-clock, never allocation counts.** U2b: events
   −13.5%, wall +55% (`hof-elimination-closure-alloc-reduction.md:1309–1317`).
   Post-P6 a create is a bump-pointer alloc+store. The paper's speedups are
   match dispatch → direct calls → inlining.
2. **Census-first, per phase.** Nothing is built until E0 ranks its target
   population. The dispatch census is to this plan what `ECO_CLOSURE_STATS` was to
   the H-plan.
3. **Two channels.** Channel A = EcoPAPSimplify P1/P4 (locally-visible
   papCreate+extend → direct `$cap` call; LSS-independent). Channel B = the
   AbiCloning stamp — the only mechanism for closures the compiler cannot see being
   created. No phase may re-implement Channel A.
4. **Standing constraints:** static routes first; no per-module intrinsics;
   flag-off byte-identical; every knob that changes *front-end artifacts* joins the
   compile-cache hash token; corpus gates need touch-all-`.elm` first.

## 2. Current state (verified anchors)

- Exploitation today = singleton stamps only: `AbiCloning.stampCall`
  (`AbiCloning.elm:970–1008`) → `generateFastDispatchCall` (`Expr.elm:1687–1796`,
  emits saturated papExtend with `_call_kind="singleton_fast"`, `_fast_evaluator`,
  `_capture_abi`) → `emitFastClosureCall` (`EcoToLLVMClosures.cpp:1136–1202`:
  typed capture loads + one call to `$cap`, unboxed primitive return).
  ~3,140 stamped sites at self-compile scale; dynamic weight unknown.
- Decline histogram: 100% of `declinedShape` = `declinedShapeArity`
  (PAP consumption). Sub-counters already exist (`AbiCloning.elm:93–110`) and print
  via the `lss globalopt:` line (`Builder/Generate.elm:911–946`).
- `wrappersInserted` **already exists end-to-end** (`Staging/Rewriter.elm:33,532` →
  `Staging.elm:89–92` → `Builder/Generate.elm:917–918`). E0 only records it.
- `ECO_CLOSURE_STATS` machinery to clone for E0: `RuntimeExports.cpp:546–673`
  (`ClosureStatsEntry`, 64Ki open-addressed CAS table, `closureStatsInit` env gate,
  `atexit` dump with `anchor=eco_alloc_closure:0x…` for ASLR sliding,
  `eco_closure_stats_dump()` embedder hook). Symbolizer:
  `benchmarks/closure-census.sh` (anchor + `nm` greatest-lower-bound lookup).
- The generic funnel to instrument: `eco_apply_closure_eval`
  (`RuntimeExports.cpp:1604–1752`) — under-saturated branch `:1688`, exact `:1711`,
  over-saturated `:1722–1749` (recurses); `eco_apply_segmentation_unknown` `:1781`
  (forwards into the same funnel). Fast-dispatch sites never enter the runtime.
- Dead plumbing (do not extend, feed or delete per phase): `_dispatch_mode` C++
  tier (no producer); `callInfo.closureKind` stamped but never emitted on calls;
  unreached `else if (closureKind)` branch (`EcoToLLVMClosures.cpp:2093–2096`);
  char gate (`AbiCloning.elm:1026–1028, 1062–1063`); `AbiCloningStats.dbg*`
  counters marked "remove before commit" (`AbiCloning.elm:105–110`).
- Subst engine constructs `ClosureInfo.srcLambda = Nothing` at both closure sites
  (`Specialize.elm:1502, 1787`) — A1's prerequisite (A1.0).
- `EcoBackend.cpp`: default/`cgu` tiers run the full -O2 `PassBuilder` pipeline with
  the CGSCC inliner (`:105–115, 190–192`); the Dev/parallel tier runs
  `runNoInlineFunctionPipeline` — AlwaysInliner only (`:161–182`). No inline hints
  anywhere on `$cap`; `emitFastClosureCall` calls indirectly through
  `AddressOf($cap)` (`:1187–1199`).

## 3. Execution order and decision tree

```
E0 (census) ──┬─ dispatch events negligible? ──→ STOP E-track; E8 only; A-track continues
              ├─ E1 audit (always; half-day)
              ├─ PAP bucket big? ──→ E2
              ├─ k∈[2..8] ≥ ~10%? ──→ E3 (E3.0 design step first)
              ├─ join-widened hot HOFs? ──→ E5 (solver route) …or E6 if A1 GO
              └─ wrappers collide with stamps? ──→ E7 (design first)
A1 spike (parallel to E1/E2) ─ parity? ──→ GO: E-track runs on subst; E6 replaces E5
                                └─ NO-GO: E-track stays solver-gated; record why
```

E0 → E1 → E2 (+E4c) are unconditional-order. A1 runs in parallel with E1/E2.
E3/E5/E6/E7 are data-chosen. E8 is externally scheduled (borrow plan).

**Gate verdicts as of 2026-07-16 (from E0/E1 results, details in §4/§5):** E0 DONE
(Run A 922.3 M dispatches; Run B coverage 1.75 %/3.52 %; stamped ≠ hot; 89.3 % of
arrows `LTop`). E1 audit DONE — devirt already works, inlining is the gap (E1.3),
payoff scales with coverage → do E1.3 with/after a coverage phase. **E2 GO** (gate
met, §6/E2.−1). **E3 deprioritized** (multi-sets = 0.8 % of arrows). E5/E6 await
analysis-precision work + A1; E8 external. The hot-dispatch ceiling is
analysis-side (trivial signatures + escape-to-data soundness), not mechanism-side.

---

## 4. E0 — Dispatch census

**Deliverable:** `benchmarks/dispatch-census-baseline.md` with the decision table
for every later phase. All code env-gated; default builds byte-identical.

### E0.1 Runtime counter table (`runtime/src/allocator/RuntimeExports.cpp`)

Clone the closure-stats section (new section directly below it, `:546–673` as the
template), with these deltas:

```cpp
struct DispatchStatsEntry {
    std::atomic<uint64_t> fp{0};    // closure->evaluator ($clo fp)
    std::atomic<uint64_t> sat{0};   // saturated indirect evaluator calls (dispatch total)
    std::atomic<uint64_t> gen{0};   // subset of sat reached via the generic funnel
    std::atomic<uint64_t> fast{0};  // stamped direct $cap executions (coverage; E0.4)
};
```

(See E0.2 for why the counters are `sat`/`gen`/`fast` rather than the original
funnel-branch split.) Same 64Ki slots / 128-probe / CAS-claim pattern; totals
`g_dispatch_{sat,gen,fast}_total`; env gate `ECO_DISPATCH_STATS` (same
`getenv`+`static bool` idiom as `closureStatsInit`); `atexit` dump + exported
`extern "C" void eco_dispatch_stats_dump(void)`.

Dump format (reuse the existing anchor symbol so one slide computation serves both
censuses):

```
[dispatch-stats] anchor=eco_alloc_closure:0x<runtime addr of &eco_alloc_closure>
[dispatch-stats] sat=S gen=G typed=T fast=F distinct=D overflow=V     (typed = sat-gen)
[dispatch-stats] fp=0x… sat=… gen=… fast=…                            (sorted by sat, desc)
```

Recorder: `void dispatchStatsRecord(const void* evaluator_fp, DispatchKind k)` —
identical probe loop to `closureStatsRecord`.

### E0.2 Instrument the dispatch primitives (CORRECTED during implementation)

**Design correction (2026-07-16, verified by an adversarial review + code trace).**
The original plan counted at the *generic funnel* branches (`eco_apply_closure_eval`
under/exact/over + `eco_apply_segmentation_unknown`). That measures the wrong
layer: it MISSES the statically-known-saturated dispatch path
(`emitInlineClosureCall` → `eco_closure_call_saturated{,_eval}` → indirect call
through `closure->evaluator`), which never enters the funnel and is likely the
DOMINANT category post-monomorphization (mono knows arities, so most sites lower
to the typed-saturated path, not the generic funnel). Since that path is exactly
what LSS singleton stamping converts, missing it would make the baseline
undercount the prize. The built census therefore counts at the **evaluator-call
primitives**, where every dynamic dispatch is visible exactly once.

There are exactly two leaf primitives that invoke `closure->evaluator` (verified —
grep `->evaluator(` yields one site; all other saturated calls funnel through
`invokeSaturatedTyped`'s K-switch):

- `invokeSaturatedTyped` entry (`RuntimeExports.cpp:~2493`, after the null-assert)
  → `Sat`. Covers funnel-exact (`eco_apply_closure_eval:1716`),
  `eco_closure_call_saturated_eval` (typed path), and `eco_closure_call_saturated`'s
  K!=0 branch — i.e. every typed saturated call.
- `eco_closure_call_saturated`'s K==0 boxed-result direct call (`:~2471`, before
  `closure->evaluator(combined_args)`) → `Sat`. The one indirect call that bypasses
  `invokeSaturatedTyped`. Mutually exclusive with it (K!=0 returns first), so no
  double-count.

Counters (the evaluator code pointer is invariant under GC relocation, so reading
it pre-splice keys to the fp actually called):

- `sat`  — every saturated indirect evaluator call. THE dynamic-dispatch total and
  the LSS-convertible population.
- `gen`  — the SUBSET of `sat` reached via the generic/unknown-saturation funnel,
  tagged at `eco_apply_closure_eval`'s exact + over branches (each leads to exactly
  one `sat` for that stage; over-saturation tags one `gen` per recursive stage).
  `typed = sat − gen` is the statically-known-arity (emitInlineClosureCall) share.
- `fast` — statically-stamped direct `$cap` executions (E0.4). LSS coverage =
  `fast / (sat + fast)`.

NOT counted: under-saturated applies (num_args < remaining) do not call the
evaluator — they grow a PAP via `eco_pap_extend`, an allocation already in the
closure census (`ECO_CLOSURE_STATS extends`). Sanity invariant for validation:
`gen ≤ sat`.

### E0.3 Symbolizer

`benchmarks/dispatch-census.sh` — clone of `closure-census.sh`; line-match regex
`[dispatch-stats] fp=0x… sat=… gen=… fast=…`, prints `sat gen typed fast symbol`
(typed = sat−gen computed per row). Anchor logic shared verbatim (same
`anchor=eco_alloc_closure:0x…` line, same `nm` GLB lookup). fp values are `$clo`
evaluator addresses — text symbols, covered by `nm -C | awk '$2 ~ /[tT]/'`.

### E0.4 Fast-dispatch execution counter (lowering-time, census builds only)

Fast sites never enter the runtime, so counting requires emitting an increment at
the site. Do it at **lowering time** (not front-end): in `emitFastClosureCall`
(`EcoToLLVMClosures.cpp:1136`), when `getenv("ECO_LSS_DISPATCH_SITE_COUNTERS")` is
set in the lowering process, emit — immediately before the `$cap` call — a call to
a new runtime helper:

```cpp
extern "C" void eco_dispatch_stats_fast(void* evaluator_fp);   // → dispatchStatsRecord(fp, Fast)
```

passing the `AddressOf` of the *generic* clone symbol (the `$clo` sibling of the
stamped `_fast_evaluator`, i.e. strip the `$cap` suffix and re-suffix `$clo`;
captureless single-clone closures use the bare symbol) so the fast row keys to the
same fp the generic rows use and the join is trivial.

Implementation notes (each one has bitten before):
- Declare the helper via a `getOrCreate*` function **and add it to
  `materializeAllRuntimeDecls`** (post-freeze assertion in parallel lowering —
  the H4.2 gotcha).
- The helper allocates nothing and must be treated as a GC-leaf call — follow the
  existing leaf-call precedent (`eco_gc_push_stack_range` et al.), i.e. keep it out
  of the statepoint-rewritten set so no ptrtoint-across-statepoint issue arises
  (REP_LLVM_001).
- Because this is read at lowering time it does **not** touch front-end artifact
  caches — but the E2E harness's *binary* compile cache is mtime-blind, so this env
  must only ever be used in the manual census workflow (E0.6), never under the
  harness. Say so in a comment at the getenv site.

### E0.5 Compiler-side join data (solver+LSS builds)

Runtime rows are keyed by `$clo` fp → symbol. To attribute symbols to lambda-set
facts, add a per-member dump behind a new env `ECO_MONO_LSS_SITES=1` (read where
`ECO_MONO_LSS_REPORT` is read, `Builder/Eco/Config.elm:280–299` pattern; report-only,
excluded from the config hash like `report`):

- In AbiCloning, after the instance index is built, print once per member:
  `lss member id=<m> label=<lamLabels[m]> instances=<lambdaId symbols, comma-sep>`.
- In `stampCall` and each decline helper (`AbiCloning.elm:1088–1148`), print per
  consulted site: `lss site anno=LSet[<ids>]|LTop k=<size> outcome=<stamped|reason>`.
  (Volume is fine — it goes to stderr with the report; the census workflow already
  captures stderr.)

Join procedure (documented in the baseline doc): runtime symbol → member via the
`instances=` lists; sites histogram by `k` and outcome via the `lss site` lines.

### E0.6 Census runs (manual, native AOT — the H6 flagship workflow)

For each configuration: fresh eco-stuff for the workload, build the native
compiler binary, then from `/work/build/compiler/build-kernel` run the Stage-7a
self-compile (`make` of `/work/compiler/src/Terminal/Main.elm`) with
`ECO_DISPATCH_STATS=1 2> census.log`, then
`benchmarks/dispatch-census.sh <binary> census.log 40`. Sort the raw log before
hand-analysis (the script takes the first N matching lines). **3 repeats minimum**;
also one run with `ECO_CLOSURE_STATS=1` co-enabled to confirm the two tables
coexist.

**E0 IMPLEMENTED + Run A DONE (2026-07-16).** E0.1/E0.2/E0.3 shipped (adversarial
3-lens review clean; the review caught the funnel-vs-primitive layer bug fixed in
E0.2). Run A baseline recorded in `benchmarks/runtime-calls.md`: **sat = 922.3 M
dynamic dispatches** on the subst Stage-7a self-compile (gen 98.1 % / typed 1.9 %,
fast 0, 5,990 distinct, deterministic ×3, output byte-identical → non-perturbing).
The prize is large and head-concentrated: `List.cons`-as-HOF = 15 % alone, then the
TypeCheck.IO monadic-bind continuations (the same lambdas that top the allocation
census). **E0.4 also SHIPPED + Run B DONE (2026-07-16):** the fast counter is wired
in `emitFastClosureCall` (keyed on the live `closure->evaluator`); a solver+LSS-built
binary lowered with `ECO_LSS_DISPATCH_SITE_COUNTERS=1` gives **LSS coverage = 1.75 %**
on the subst workload (fast 16.1 M / 921.8 M) and **3.52 %** in the full solver world
(fast 65.0 M / 1.84 B). **Decisive finding: stamped ≠ hot.** The top-20 evaluators by
dispatch (`List.cons`, IO continuations, `Basics.identity`) are ALL `fast=0`; the
stamped closures have `sat=0` (always-fast, and cold). Singleton stamping never
reaches the high-frequency HOF-arg / stored-continuation closures — the E2/E3/E5–E6
population. So the E-track's ceiling is ~the 98 % of dispatch that is currently
generic, and the immediate levers are PAP-shape (E2) and small-set (E3), not more
singleton coverage.

**E0.5 DONE (2026-07-16) via the existing `ECO_MONO_LSS_REPORT` (no code change
needed — its mono-side census already carries the deciding data).** Set-size
histogram over 388,035 zonked arrows: **only 10.7% carry a concrete `LSet`; 89.3%
are `LTop`.** Concrete sets are 92% singletons (38,371); **multi-member `LSet[2..8]`
are just 3,164 (0.8% of arrows)** (2→1625, 3→981, 4→299, …, 8→11). Widening cause:
`byKernel=3004`, `bySize=35`, `byBudget=0` — so the 89% `LTop` is overwhelmingly
UNCONSTRAINED, not widened. **All 8,673 def signatures are trivial** → the analysis
propagates ~no cross-def set flow; sets come only from per-item lambda grounding.
Singleton declines are 99.2% `arity` (6,801/6,856).

**Verdict — coverage is ANALYSIS-limited, not mechanism-limited, and it reorders the
E-track:**
- **E3 (small-set dispatch) is DEPRIORITIZED.** Its entire target is the 3,164
  multi-sets (0.8%); the gate ("k∈[2..8] ≥ ~10% of dispatch") fails on the static
  population. (One residual: the per-site×census join, the only thing the built
  E0.5 code would add, could still show a few multi-sets are super-hot — build it
  only to de-risk an E3 bet, which the data already argues against.)
- **E2 (PAP-shape stamping) is the clean bounded win** — 6,801 arity-declined
  singletons, identity already known. Do it.
- **The hot dispatch lives in the 89% `LTop`, and that is the real ceiling.** It
  splits by cause: (i) HOF-argument closures (`List.cons`, `Maybe.map`) are `LTop`
  because signatures are trivial + the local-multi transport gap (§8.4) — reachable
  only by ANALYSIS precision (E4a V1 transport, per-use let sets §7.4) plus keyed
  per-call-site specialization (E5/E6, the paper's core mechanism); (ii) the IO
  bind continuations are `LTop` by SOUNDNESS (they escape into the returned IO
  value) — no analysis precision helps; they need defunctionalization / the borrow
  track (E8). So the biggest prize is gated on analysis+keying (E4a/E5/E6) and E8,
  not on new dispatch lowering.
- **A1 (LSS-Lite) note:** any post-mono re-inference must clear the same 89%-LTop
  bar — decoupling from the solver is orthogonal to the coverage ceiling.

Remaining E0: E0.8 (dbg* cleanup). The `ECO_MONO_LSS_SITES` per-site code path
(§E0.5 original) is now optional — build it only to weight the 3,164 multi-sets by
runtime dispatch (the E3 de-risk).

Configurations:
1. **Run A — subst-built default binary** (the shipping configuration): total
   generic-apply event count = the whole E-track prize on what users run. **DONE.**
2. **Run B — solver+LSS-built binary** (`ECO_MONO_ENGINE=solver`, LSS default-on;
   build the binary itself with `ECO_LSS_DISPATCH_SITE_COUNTERS=1` for the fast
   rows; capture the compile's stderr with `ECO_MONO_LSS_SITES=1` for E0.5's join
   data): stamped-site weight, per-|set| attribution, decline-outcome ranking.
3. **Run C — ARM=0 attribution run (§15.1 trigger 1):** solver? no — ARM=0 is the
   subst-side `ECO_ARITY_RAISE=1 ECO_ARITY_RAISE_MIN_APPLIED=0` build. Census it
   vs Run A: if generic-apply events explode in the raised callers, the U2b +55%
   attribution is confirmed with data.

### E0.7 Baseline doc + decision table

`benchmarks/dispatch-census-baseline.md`: totals per run; top-40 symbol table per
run; Run B split by (stamped-fast / LSet-singleton-declined / LSet k∈[2..8] / LTop /
PAP-arity-declined); `wrappersInserted` and the `lss globalopt:` counters copied
from the compile log; the E1–E7 gate verdicts (each phase's "gate to build" answered
YES/NO with the number that decided it).

### E0.8 Housekeeping (same commit)

Delete the `AbiCloningStats.dbg*` counters (`AbiCloning.elm:105–130` and their
increment/print sites) — they are self-labeled "remove before commit" debt and E0
touches every one of those files anyway.

### E0.9 Gate

Default (env unset) builds byte-identical — trivially, all paths are env-gated;
one `--target full` green (`cmake --build build --target full 2>&1 | tee
/tmp/test_output.txt`, grep the file, run ONCE); baseline doc committed.

---

## 5. E1 — Make the direct calls actually inline

### E1.1 Audit (half day, no code)

On the Run-A binary (and once on a default-tier vs Dev-tier pair):

```
nm -C --size-sort <bin> | grep '\$cap' > caps.txt                  # surviving $cap bodies + sizes
objdump -d --no-show-raw-insn <bin> > dis.txt
grep -c 'call.*\$cap' dis.txt                                      # direct calls to $cap
grep -B2 'call.*\*%r' dis.txt | grep -c '\$cap'                    # address-materialized indirect calls (approx)
```

Questions to answer: (a) did LLVM fold `AddressOf($cap)`+indirect into direct
calls at -O2, or do `lea …$cap` + `call *reg` pairs survive? (b) how many
sub-~40-instruction `$cap` bodies still exist with call sites (i.e. not inlined)?
(c) spot-check three hot evaluators from E0's table — are their `$cap` bodies
inlined into their callers? Record per backend tier; the Dev tier
(`runNoInlineFunctionPipeline`, `EcoBackend.cpp:161–182`) is expected to inline
nothing — every dev-loop wall number understates Channel A+B and must say so.

**E1.1 AUDIT DONE (2026-07-16, default/cgu tier binaries).** Two findings that
reshape E1:
- **(a) Devirtualization already works — E1.2 is largely unnecessary.** The entire
  ~60 MB binary has only **409 indirect `call *` instructions** (identical in the
  subst and solver-built binaries). LLVM at -O2 folds the `AddressOf($cap)`+indirect
  fast-call into a direct call already; the 409 are the runtime's genuine dispatch
  primitives (`invokeSaturatedTyped`'s K-switch etc.) plus a few function-pointer
  tables. So emitting a direct symbol call buys ~nothing — the optimizer beat us to it.
- **(b) Inlining is the real gap.** **9,449** (subst) / **10,264** (solver) direct
  `call <…$cap>` sites survive un-inlined, against **18,422 `$cap` bodies of which 55 %
  are ≤64 bytes** (mean 190 B). Small, trivially-inlinable clone bodies are being
  called directly but NOT inlined into their callers — so the cross-boundary
  optimization the paper's speedups come from is absent. Likely inhibitors (to
  confirm in E1.3): GC-statepoint conservatism around `addrspace(1)` values, and the
  backend's parallel/`--split-codegen` partitioning (a `$cap` and its caller in
  different partitions cannot inline). **E1.3 (`inlinehint`/`alwaysinline` on `$cap`,
  or same-partition placement) is the lever, not E1.2.**
- **Strategic caveat — E1's payoff scales with coverage.** The HOT dispatch
  (`List.cons`, IO continuations) is GENERIC (routed through the runtime, not `$cap`),
  so `$cap` inlining only benefits the fast + Channel-A slice — under subst that is
  Channel A (weight unmeasured; no counter on P1/P4 direct calls); under solver only
  the +16 M fast events. So E1 is a **multiplier on E2/E3/E5 coverage growth**, not a
  large standalone win today. Do E1.3 alongside/after the first coverage phase, and
  add a Channel-A direct-call counter if its weight needs sizing.

### E1.2 Direct symbol call in `emitFastClosureCall`

Replace the `AddressOf` + indirect `LLVM::CallOp` (`EcoToLLVMClosures.cpp:
1187–1199`) with the direct-callee `LLVM::CallOp` form (symbol ref + the same
`LLVMFunctionType`). Keep the safepoint marker emission (`:1197–1198`) unchanged.
Pin: new `test/codegen/fast_dispatch_direct_call.mlir` — RUN through the lowering,
`CHECK: llvm.call @{{.*}}\$cap(` and `CHECK-NOT: llvm.mlir.addressof`.

### E1.3 Inline hints on `$cap`

Attach LLVM `inlinehint` to every `$cap` function at func→llvm.func conversion
(the `passthrough` attribute array is the mechanism; find where existing function
attributes are set in the lowering and append). Start with plain `inlinehint` on
all `$cap`; escalate to size-bounded `alwaysinline` only if E1.5's A/B says the
cost model still refuses hot small bodies. Do NOT touch the Dev tier's pipeline in
this phase (its no-inline property is a deliberate compile-speed choice) — record
it as an open question (§16.5).

### E1.4 Statepoint-order sanity

Confirm the RS4GC/statepoint rewrite runs after LLVM inlining in both tiers
(read the `PassBuilder` setup at `EcoBackend.cpp:105–115, 190–192` and the custom
pipeline at `:161–182`); if any tier inlines post-RS4GC, stop and re-plan (that
would break relocation semantics). One sentence in the commit message stating
where each tier rewrites statepoints.

### E1.5 Gate

Codegen suite green; `--target full` green; interleaved wall A/B ×3 per side on
the native Stage-7a self-compile (±3–5 s noise band; both runs default tier);
front-end `.mlir` artifacts byte-identical (E1 is lowering-only); E0 re-census
optional (call counts shouldn't move — only their cost).

---

## 6. E2 — PAP-shape stamping (absorbs H6.3 V3)

**Design in one line:** a PAP of member `m` with `k` stored args is, for calling
purposes, a closure whose captures are `m`'s real captures followed by the `k`
applied args — so stamp `captureAbi.captureTypes = m.captures ++ take k m.params`
and `paramTypes = drop k m.params`, and **`generateFastDispatchCall` +
`emitFastClosureCall` work unchanged** (they load `|captureTypes|` slots and append
site args).

### E2.−1 What E0 settled (2026-07-16) — build-gate verdict, numbers, expectations

Fresh HEAD numbers (unkeyed solver, `ECO_MONO_LSS_REPORT` Stage-7a run):
`dispatchUpgraded=2395`; declines `declinedShape=6856 (arity=6801 bucketMiss=17
layout=37 char=1 nonArrow=0)`, `declinedNoInstance=524`, `declinedAbiMismatch=2`.
So **the arity/PAP class is 6,801 sites — 99.2 % of shape declines and ~70 % of
every singleton site the stamper consults.** (The "~3,140 stamped" figure in §2 was
the K1 *keyed* gate; unkeyed HEAD stamps 2,395 — use 2,395 as E2's baseline.)

**Build-gate verdict: PROCEED, with bounded expectations.** The static half of the
gate is met (the class dominates declines). The dynamic half is deliberately not
pre-measured: Run B showed the *hot* dispatch rows (`List.cons`, IO continuations)
are `LTop`, so E2's direct dynamic win is expected to be modest — and the E0.4 fast
counter makes the actual value a free by-product of the post-E2 re-census (counts
are deterministic; one run suffices). **Strategic role (why build it anyway):**
arity/PAP-consumption is the #1 decline *mode of the stamping machinery itself*.
E5/E6 keyed fan-out — where the big prize lives — will mint many more singleton
sites, and partial-application sites among them will present this same PAP shape.
E2 removes that mode once, ahead of the phases that need it.

Execution order within E2: E2.0 pins → E2.3 CallInfo plumbing (mechanical, wide) →
E2.2 resolution + stamping → E2.4 tests → E2.6 gates + re-census.

**E2 IMPLEMENTED + GATED (2026-07-16).** Everything below shipped:
`fastPapPrefix` CallInfo field (+5 construction sites), `resolveRepresentative`
arity split (`zero/under/over` sub-counters) + `resolvePapSuffix`/`papScan` +
`StampPap` arm in `stampCall`, `_pap_prefix` emission + real-capture-count
symbol choice in `Expr.elm`, report-line extension (+ E0.8 dbg* cleanup),
LSS_011 in `invariants.csv`, pins `test/codegen/fast_dispatch_pap_prefix.mlir`
(JIT, 753 — slot order + merged-ABI lowering) and
`test/elm/src/HofPapPrefixDispatchTest.elm` (behavioral). Gates: full E2E
**1620/1620** (default) green incl. both new tests; flag-on JIT correctness of
the test module (`result: 22564` under solver); flag-on corpus
**1620/1620 PASSED** under `ECO_MONO_ENGINE=solver` (touch-all first — genuine
recompiles). elm-tests: **12987/16 — the 4
delta-vs-baseline failures are PRE-EXISTING at HEAD** (A/B-proven: identical
with the E2 suffix arm neutralized): `majority2Flat` + "Case returns
differently staged lambdas" under the flag-on unit leg (`runToGlobalOptLssOn`)
emit a papExtend with NO `remaining_arity` and no exempt `_call_kind` — a
latent solver+LSS staging-emission defect (plausibly H6.2-Layer-1-era) that
needs its own investigation; E2 neither causes nor masks it. NOTE: contrary to
the E0-era finding, automated flag-on coverage DOES exist — the TestLogic
SourceIR suites run every fixture through `runToGlobalOptLssOn`
(`tests/TestLogic/TestPipeline.elm:356`) — new flag-on pins belong there.

**Activation status (verified live):** the suffix arm is correctly
conservative and currently near-dormant — the v1 analysis grounds members on
HEAD arrows only, while every PAP-application site has a peeled INNER-arrow
type, so genuine PAP-dispatch sites are not yet consulted (annos `LTop`); the
one consulted partial site in the probe (`f 10`, staged return) was correctly
DECLINED by the return-layout fence (stamping it would miscompile). E2 is the
mechanism half; activation arrives with inner-arrow set transport (E4a-class)
or keyed fan-out (E5/E6) — exactly the "analysis-limited" E0.5 verdict. The
post-E2 re-census is therefore deferred to those phases (no coverage delta to
measure today).

**AS BUILT (2026-07-16) — three corrections discovered during implementation:**

1. **The hook point is NOT the arity decline — it is bucketMiss/layout-exhaustion.**
   `resolveRepresentative`'s arity guard compares the site's arg count to the
   site's OWN callee type (`argCount == |fargs|`), not to the instance. A
   saturating call on a PAP value PASSES that guard (its peeled type has exactly
   the applied params) and then misses the bucket (the instance is bucketed under
   its FULL param fingerprint) — today's `bucketMiss=17`. The 6,801 `arity`
   declines are sites that DON'T saturate their own type: under-applying sites
   (which CREATE PAPs — no dispatch to convert), over-applying flat multi-stage
   calls (dispatch exists; needs staging-aware stamping — v2), and bare
   references (argCount=0). As built: `resolvePapSuffix` hooks at bucketMiss AND
   at group-exhaustion (`bumpShapeLayout` path), scanning all of the member's
   groups for a k-dropped suffix match; the arity decline is split into
   `declinedShapeArity[Zero|Under|Over]` sub-counters so the report finally
   sizes those populations. Consequence: E2's static target is the bucketMiss
   class (small today) plus whatever E5/E6-minted singletons produce later — the
   6,801 was never the PAP-stampable population (the plan's own "bounded
   expectations" verdict stands, with sharper attribution).
2. **Captureless members need the bare symbol.** `fastSymbol` keyed `$cap` on
   `captureTypes` non-empty; under a PAP stamp the merged captureTypes is
   non-empty even for captureless members, which have NO `$cap` clone. As built:
   `fastDispatchStamp` returns the papPrefix k and the suffix decision keys on
   the REAL capture count (`|captureTypes| − k`).
3. **No automated flag-on report pins exist.** The E2E harness sets no env and
   pins only runtime output (`-- CHECK: result:`); the existing `Lss*Test`
   "dispatchUpgraded=1" pins are doc comments, not assertions. As built: the E2E
   test (`HofPapPrefixDispatchTest.elm`) pins correctness under the default
   pipeline (LSS_005) with a shape that survives forwarding/merging/loopification
   (two-use let-bound partial inside a recursive HOF); the `stampedPapPrefix`
   assertion is a MANUAL gate step (solver+report compile of the test module +
   self-compile). The codegen pin (`fast_dispatch_pap_prefix.mlir`, `-emit=jit`)
   validates the merged-ABI lowering + slot order end-to-end (753 vs 573).
   E2.0 premise 3 fully settled: papCreate packs `arity` = TOTAL slots
   (`max_values`), `n_values = numCaptured` (`EcoToLLVMClosures.cpp:736–762`;
   the multi-use-fast-evaluator test uses arity=2 for 1 capture + 1 param).

### E2.0 Verify the object-layout premises (before any compiler change)

Premises 1–2 need pins; premise 3 was settled by code read during E0 and needs one
residual pin.

1. **Slot order:** a PAP's value slots are `[captures…, applied args…]` in
   append order. papCreate stores captures from the values offset
   (`EcoToLLVMClosures.cpp:748–753` per the P6 notes); `eco_pap_extend` appends;
   P6-fused creates preserve operand order; interned zero-capture singletons +
   extend produce `[args…]`. Pin with a unit `.mlir` that creates a 2-capture
   closure, extends with 1 arg, and direct-calls `$cap` loading 3 slots.
2. **Slot kinds:** extend converts args to the slot's DECLARED kind at store time
   (the Phase-D contract; `GenericApplyBoxing` unit tests document it), and creates
   declare kinds for future arg slots. Therefore the k applied slots hold `m`'s
   declared param kinds. Extend the `GenericApplyBoxing` test file with a
   prefix-load case.
3. **Header accounting — SETTLED (E0 code read), one residual pin.**
   `eco_closure_call_saturated` allocates `combined_args = alloca(max_values)` and
   `spliceArgsForSaturatedCall` fills it with captures + newargs before invoking
   the evaluator (`RuntimeExports.cpp:2426–2471`); saturation everywhere is
   `n_values + num_newargs == max_values`. Therefore **`max_values` = TOTAL
   evaluator slots = |captures| + |params|**, **`n_values` = filled slots =
   |captures| + applied args**, `remaining` = unapplied params. (The interned
   zero-capture case `max_values = arity` is the c = 0 degenerate; and
   `eco_alloc_closure_k`'s `num_captures` parameter (`RuntimeExports.cpp:688–689`,
   sets `max_values = num_captures`) actually receives the evaluator's total slot
   count — a naming quirk, not a contradiction.) The stamped claim
   `n_values = c + k`, `k = |m.params| − siteArgs` follows directly.
   **Residual pin:** read the papCreate lowering's header packing
   (`EcoToLLVMClosures.cpp:~748`) and confirm it packs
   `max_values = numCaptured + arity` (equivalently, that its `arity`/packed field
   means total slots when captures are present); write the confirmed wording into
   LSS_011 (E2.5).

If premise 1 or 2 fails, stop and re-derive — the rest of the phase is mechanical
only because of them.

### E2.1 Fences (v1 scope) — with k defined precisely

Let `A = |inst.paramTypes|` (the resolved instance's fast-clone param count, i.e.
the `Instance` record `stampCall` already consumes at `AbiCloning.elm:987–991`)
and `n = siteArgCount`. Stamp only when ALL hold, else decline into the existing
counters:

- singleton `LSet [m]` and instance resolution passes LSS_009 exactly as today
  (blocker instances, abiKey unanimity — unchanged);
- `n ≥ 1` (a 0-arg site is a bare reference — nothing saturates) and
  `k = A − n ≥ 1`;
- **PAP-aware layout match** (this replaces today's exact-arity comparison for the
  PAP arm): `eqLayout` of the site's peeled callee param layout against
  `List.drop k inst.paramTypes`, and of the site's return against
  `inst.returnType` — i.e. the site saturates exactly the instance's remaining
  suffix;
- the instance is **single-stage** (no nested `MFunction` stage structure past the
  site's application — multi-stage PAP prefixes interact with staging segmentation
  and are v2; count them in a new `declinedShapePapStaged`);
- the k prefix param kinds pass the same gates captures pass today: `charFree`
  until E4c lands (count in the existing `declinedShapeChar`), unboxability per
  the existing capture rules.

### E2.2 AbiCloning changes (decision point located)

The stamping decision is `resolveRepresentative (Mono.typeOf func)
(List.length args) memberInfo → Stamp Instance | Decline bump`, called from
`stampCall` (`AbiCloning.elm:976`; the `Resolution` type at `:1011–1013`; decline
helpers `:1088–1148`). Steps:

1. Read `resolveRepresentative`'s body (directly below `Resolution`, `:1014–1087`)
   and locate the exact arity comparison that feeds `bumpShapeArity` (`:1119`) and
   the sigKey/bucket filtering it sits in.
2. Extend the resolution: when the exact-arity match fails with `n < A`, attempt
   the PAP match per E2.1 against the SAME bucket/candidate machinery, but with the
   site layout compared to the k-dropped param suffix. Widen the result type to
   `Stamp Instance | StampPap Instance Int {- k -} | Decline (StampCtx -> StampCtx)`
   so `stampCall` distinguishes the arms (compiler exhaustiveness finds the two
   match sites).
3. In `stampCall`, the `StampPap inst k` arm stamps:
   `captureAbi = Just { captureTypes = inst.captureTypes ++ List.take k inst.paramTypes,
   paramTypes = List.drop k inst.paramTypes, returnType = inst.returnType }`,
   `fastEvaluator = Just inst.lambdaId`, `closureKind` as the exact arm does, plus
   `fastPapPrefix = Just k` (E2.3); bump `stampedPapPrefix`.
4. New counters `stampedPapPrefix` + `declinedShapePapStaged` join
   `AbiCloningStats` (`AbiCloning.elm:93–110`, zero-init `:115–131`) and the report
   line (`Builder/Generate.elm:911–946`) — current printed format is
   `lss globalopt: wrappersInserted=… dispatchUpgraded=… declinedBlocked=…
   declinedNoInstance=… declinedShape=… (arity=… bucketMiss=… layout=… char=…
   nonArrow=…) declinedAbiMismatch=…`; append `stampedPapPrefix=` right after
   `dispatchUpgraded=` and `papStaged=` inside the declinedShape parens.

### E2.3 CallInfo field + emission marker

`generateFastDispatchCall` needs no functional change — E2's stamp is
shape-compatible (its `fastDispatchStamp` gate at `Expr.elm:1650–1661` checks
`argCount == |abi.paramTypes|`, which holds by construction for the k-dropped
paramTypes). Add one attr for auditability: when `fastPapPrefix = Just k`, emit
`_pap_prefix = k` (IntegerAttr) in the attr block at `Expr.elm:1760–1775`; no C++
consumer (documentation + future verifier hook only). CallInfo carries
`fastPapPrefix : Maybe Int` — add to the record at `AST/Monomorphized.elm:1535–1537`,
`Nothing` in `defaultCallInfo` (`:1553`), then the mechanical sweep of construction
sites the compiler's exhaustiveness errors list (~10 sites: MonoGlobalOptimize
wrapper synthesis, ResolveAccessorValues, Specialize ×2, Staging/Rewriter,
MonoInlineSimplify stamp-clearing sites — the inliner must CLEAR `fastPapPrefix`
wherever it already clears `fastEvaluator`/`captureAbi`, `MonoInlineSimplify.elm:
652, 706–707, 756–757, 824–827, 2906–2907`, or a stale k survives reshaping).

### E2.4 Tests

- Unit `.mlir` pins from E2.0 (slot order; `GenericApplyBoxing` prefix-kind case).
- `test/elm/src/HofPapPrefixDispatchTest.elm` (E2E, run under
  `ECO_MONO_ENGINE=solver`): a 3-arity global partially applied with 2 args, the
  PAP passed **as a function argument** to a consumer whose cost exceeds the inline
  threshold (storing it in a record/ctor field escapes to data and stays `LTop` —
  per E0.5 that shape is out of reach by design), then applied to 1 arg; assert
  result correctness AND grep the compile stderr for `stampedPapPrefix=1` the way
  existing `Lss*Test` pins grep the `lss globalopt:` line. Variant: one boxed + one
  unboxed (i64/f64) prefix arg under tiny-nursery `ECO_HEAP_VALIDATE` (GC-move the
  PAP between partial application and call).
- Negative pins: a two-stage member's PAP declines (`papStaged=1`); a Char-prefix
  PAP declines into `declinedShapeChar` (flips when E4c lands).
- Adversarial discipline: the corpus is flag-off-shaped (LSS 3.6 lesson) — these
  pins are the only thing that fails if E2 is broken while the corpus stays green.

### E2.5 Invariant

New `LSS_011`: *"A PAP-prefix stamp (`fastPapPrefix = Just k`, emitted as
`_pap_prefix = k`) is legal only when the site's callee annotation is a singleton
`LSet [m]`, the resolved instance is single-stage, `k = |m.params| − siteArgs` with
`siteArgs ≥ 1` and `k ≥ 1`, the site's param/return layout eqLayout-matches the
instance's k-dropped suffix, and the stamped `_capture_abi` equals m's capture ABI
followed by m's first k param ABIs. The runtime object at such a site is an m-PAP
whose header satisfies `max_values = |m.captures| + |m.params|` (total evaluator
slots) and `n_values = |m.captures| + k` (filled slots), so the fast lowering's
`|_capture_abi|` loads read exactly the filled prefix"* — add to `invariants.csv`
after confirming the E2.0(3) residual pin; tested by the E2.4 pins.

### E2.6 Gate

- **Gate to build: MET** (E2.−1 — 6,801 sites = 99.2 % of declines; dynamic value
  measured after, not before).
- Gate to keep: touch-all-`.elm` + `--target full` under `ECO_MONO_ENGINE=solver`
  green; elm-tests baseline-identical (12991/12); **subst byte-identity is cheap
  and total** — AbiCloning only acts on `LSet` annos (absent under subst: all
  `LTop`) and `fastPapPrefix = Nothing` emits nothing, so one subst Stage-7a run
  must reproduce the known-good 12,007,395 B `eco-compiler-boot.mlir` exactly.
- Report deltas on the solver Stage-7a: `declinedShape (arity=…)` drops from 6,801
  toward the papStaged/char residue; `stampedPapPrefix` ≈ the difference;
  `dispatchUpgraded` stays ≈ 2,395 (the exact arm is untouched).
- **Value measurement (the E2 number):** one post-E2 Run B re-census — exact
  recipe in `benchmarks/runtime-calls.md` (solver front-end → lower with
  `ECO_LSS_DISPATCH_SITE_COUNTERS=1` → census; deterministic, 1 run per workload).
  Coverage rises from 1.75 % (subst workload) / 3.52 % (solver workload) by the
  dynamic weight of the converted sites; append the row to `runtime-calls.md`.
- Afterwards: the §15.1 U2b trigger-2 re-measure (one interleaved ARM=0 A/B)
  becomes due — E2 is the phase that was named in the U2b disposition.

---

## 7. A1 — LSS-Lite: post-mono lambda-set inference (decoupling spike)

Target: singleton stamps (Channel B) under the **subst** engine at parity with
unkeyed solver-LSS. Timebox: ~1 week; throwaway allowed; go/no-go on parity
numbers.

### A1.0 Prerequisite — thread `srcLambda` through the subst engine

`Specialize.elm` constructs `ClosureInfo` with `srcLambda = Nothing` at `:1502`
and `:1787`. The source tag exists engine-independently (`TOpt.Function
(Just lamId) …`, stamped by `AssignMVarIds`). Thread it: both construction sites
take the enclosing `TOpt.Function`'s tag (the surrounding code already pattern-
matches the Function node to get params/body — pull the first field through).
Inliner/staging propagation rules already exist engine-agnostically (OQ6 verbatim
copy; LSS_008 wrapper propagation in `Staging/Rewriter.elm` reads
`originalInfo.srcLambda`). Gate: flag-off byte-identity of `.mlir` output
(srcLambda is never emitted), full E2E green.

### A1.1 The pass (`Compiler/GlobalOpt/LambdaSetLite.elm`, new)

Pipeline position: inside `globalOptimize` immediately **before Phase 4
AbiCloning** (`MonoGlobalOptimize.elm:146`) — after staging, so the values it
annotates are the final ones AbiCloning indexes, and LSS_008-propagated wrapper
`srcLambda`s are visible. Gated on new config `lss.lite : Bool` (default False),
env `ECO_MONO_LSS_LITE=1`, hash token `lssl=1` (this DOES change artifacts).
When the engine is solver (annos already present), `lite` is ignored — assert or
no-op, decide in review.

Algorithm (id-only sets over ground types — Int-DSU + one worklist; no
`Type.Unify`):

1. **Slot minting.** One traversal of the pruned graph; for every arrow occurrence
   in a type reachable from a node (node result types, binder/param types, closure
   types, capture-recorded types, call annotation types), mint a dense slot id.
   Key: traversal is deterministic; keep a side map from each *typed position you
   will need to find again* (spec params/results per SpecId; per-node binder names)
   to its slot list, mirroring how `loadTypeWithArrows` defines ordinals (LSS_006's
   moral equivalent).
2. **Union edges (v0 set):**
   - closure literal: seed `srcLambda` (or the interned-member key for
     global/ctor/kernel *values* — reuse the `"g|" / "c|" / "k|" / "a|"` key scheme
     from `Engine.memberIdFor`) into its own head slot;
   - let/def binder ↔ every use (names are unique post-freshening; chain-level,
     remembering the letrec earlier-sibling trap);
   - `MonoCall` with known callee spec: arg-i slots ↔ spec param-i slots,
     result ↔ spec return (peeled per stage exactly as `computeCallInfo` peels);
   - captures: capture expr slots ↔ the closure's recorded capture-type slots;
   - `MonoCase`/`MonoIf` joins: branch result slots ↔ node result slot.
3. **⊤-poisoning (v0):** any arrow slot that flows into a constructor/record/
   list/tuple field, a kernel/port boundary, or `MonoTailCall` argument positions
   the pass does not model → union with ⊤. (This is v0's deliberate precision
   loss vs the solver, which transports through data. Measure it; a v1 could add
   per-field edges for `MCustom`/`MRecord` if parity demands.)
4. **Fixpoint:** DSU union is monotone; a single worklist pass over edges suffices
   (edges are static; no re-derivation needed). Read back: slot root → `LSet`
   (sorted ids) or `LTop`; rewrite the graph's `MFunction` annos in place
   (`Traverse.mapNodeTypes` machinery).

### A1.2 Consumption

None needed: AbiCloning already runs unconditionally at Phase 4 and simply finds
all-LTop annos under subst today. With Lite annos it stamps. The LSS_002 integrity
checker (`tests/TestLogic/Monomorphize/LambdaSetIntegrity.elm`) runs as-is.

### A1.3 Parity + gates

- Soundness: LSS_002 checker green under subst+lite; full corpus
  `--target full` (touch-all first) with `ECO_MONO_LSS_LITE=1`; adversarial: the
  existing `Lss*Test` pins run under subst+lite must not stamp anything the solver
  wouldn't (compare report lines).
- Precision: `dispatchUpgraded` (subst+lite) vs (solver unkeyed) on the corpus and
  the self-compile; also join with E0's Run-B hot-site list — parity ON HOT SITES
  matters more than the global count.
- **GO** ⇒ E-track phases run under subst+lite by default and E6 becomes the
  fan-out route. **NO-GO** ⇒ record the precision gap classes in this file and
  stay solver-gated.

---

## 8. E3 — Small-set switch dispatch (k = 2..K, boxed representation unchanged)

Gate to build: E0 Run-B shows k∈[2..8] sites carrying ≥ ~10% of generic dispatch
events. Do E3.0 before any code.

### E3.0 Design-settling step (½–1 day, written into this file before coding)

1. **CallInfo representation:** new field
   `setDispatch : Maybe (List { fastEvaluator : LambdaId, captureAbi : CaptureABI })`
   (default Nothing; mechanical sweep of construction sites).
2. **Attr encoding:** on the saturated papExtend, `_call_kind = "set_dispatch"`,
   `_member_clo_evaluators : ArrayAttr<FlatSymbolRefAttr>` (the `$clo` symbols —
   these are what `closure->evaluator` holds and what the switch compares),
   `_member_fast_evaluators : ArrayAttr<FlatSymbolRefAttr>` (`$cap` targets),
   `_member_capture_abis : ArrayAttr<ArrayAttr<TypeAttr>>`. Verify ArrayAttr
   nesting is acceptable to the bytecode encoder (astral-char & attr-shape gotchas
   live there).
3. **K:** start at 4 (config `lss.maxDispatchArms`, default 4, hash token when
   non-default). `maxSetSize=8` still bounds what zonk produces.
4. **Return ABI:** members reaching one site were sigKey-filtered to the same
   param/return layout, so all arms share the site's result ABI — merge via a
   continuation block with one block argument.

### E3.1 AbiCloning multi-member arm

In `stampCall` where `headAnno` is `LSet ms` with `2 ≤ |ms| ≤ maxDispatchArms`
(today's code matches only `LSet [m]`, `:972–973`): resolve EVERY member through
the existing representative machinery (LSS_009 discipline per member — sigKey
filter to the site, abiKey unanimity per member, any blocker or `NoInstance` on
ANY member declines the whole site). Stamp `setDispatch`. New counters
`stampedSet`, `declinedSetMember` in the stats + report line.

### E3.2 Emission (`Expr.elm`)

Beside `fastDispatchStamp`: `setDispatchStamp` requiring `setDispatch = Just`,
non-empty paramTypes, argCount match on EVERY member's ABI (they agree by sigKey).
Emit the saturated papExtend with E3.0's attrs; result SSA type = the site's mono
return ABI, as `generateFastDispatchCall` does (`:1726–1727`).

### E3.3 Lowering (`EcoToLLVMClosures.cpp`)

New `emitSetDispatchCall`, dispatched from the PapExtendOp saturated branch
(`:2070–2096`) when `_member_clo_evaluators` is present (check BEFORE the
`fastEval && captureAbi` case): load `closure->evaluator` (the offset is already
used by `invokeSaturatedTyped`); an if-else chain (k ≤ 4) comparing against
`AddressOf(mi$clo)`; arm i = the body of `emitFastClosureCall` with member i's
capture ABI and `mi$cap`; default arm = the existing generic path
(`emitClosureEvalCall`). All arms `cf.br` to a merge block carrying the result.
Do NOT reuse the dead `_dispatch_mode`/`closureKind` branch — delete it in this
phase instead (it is the third dead hook; E3 supersedes it).

### E3.4 Tests

`test/codegen/set_dispatch_two_members.mlir` (structural: two compares, two direct
`$cap` calls, generic default); `test/elm/src/LssSetDispatchTest.elm` — the
paper's `maybeplus2` shape: `f = if dynamicCond then \x -> … else \y -> …` passed
to a non-inlinable HOF, both branches executed, distinct capture layouts, GC
pressure variant; report pin `stampedSet=1`. Negative pin: k=5 with
`maxDispatchArms=4` declines.

### E3.5 Invariant

`LSS_012`: *"A `set_dispatch` stamp lists, per member, a representative satisfying
LSS_009 individually; the arm order matches the sorted member ids; a generic
default arm is always present (totality via LSS_002 is NOT assumed at this
boundary)"* + a CGEN sibling for the lowering shape.

### E3.6 Gate

Gate to keep: corpus green (solver or subst+lite per A1 outcome); census delta on
E0 re-run (targeted k-sites move from under/exact rows to fast rows); wall A/B;
binary-size budget (≤ ~2% or sign-off).

---

## 9. E4 — Coverage growth (census-gated backlog)

- **E4c — char gate (do opportunistically, S):** (1) unit `.mlir` exercising the
  i16 capture load through `emitFastClosureCall` (the load path at
  `EcoToLLVMClosures.cpp:1168–1177` handles f64/ptr/i64; add the i16 arm if
  missing); (2) E2E pin: Char-capturing lambda through a non-inlinable HOF
  boundary, solver+LSS; (3) delete the `charFree` decline
  (`AbiCloning.elm:1026–1028, 1062–1063`), keep `declinedShapeChar` (should read 0
  thereafter); (4) extend CGEN_CLOSURE_005 wording to i16.
- **E4a — V1 local-multi transport (M):** solver-route precision fix
  (design §8.4 gap; `demandUnifyRoot`/`lssRootAnn` precedent in
  `Translate.elm:91–103, 2622–2628`); flips `LssSingletonLetBoundLambdaTest` from
  gap-pin to stamp-pin. Note: A1's dataflow gets this class structurally — if A1
  is GO, E4a is dead; sequence accordingly.
- **E4b — V2 wrapper-home recovery (M–L):** staging-side
  (`chooseCanonicalSegmentation` bias toward singleton-upgradable producers);
  overlaps E7 — build only under E7's gate.

Gate: E0 per-class ranking (H6.0b currently shows zero declines from these
classes; they stay backlog until the census disagrees).

## 10. E5 — Selective keyed fan-out (solver route)

Prep (do regardless): fix the stale "JS solver ≥12×/impractical" claims in the
HOF plan §H3 and the monosolver plan — overturned Jul 16 (Stage 5 = 1.79× in
12 GB; the 8h49m keyed blowup was the pre-fix JS solver; LSS_010 churn already
fixed by drain-end coalescing).

- **E5.1 Config:** `lss.keyedGlobals : List String` (comparable-gkey strings),
  env `ECO_MONO_LSS_KEYED_GLOBALS=g1,g2`, hash token `lssKG=<joined>` when
  non-empty. Gate in `enqueueSpec` (`Engine.elm:513–518`) becomes
  `lss.enabled && (lss.keyed || member gkey keyedGlobalsSet)`; the budgeted keyed
  path (`enqueueSpecKeyed:604–661`) is unchanged (both branches already route
  through the LSS_010 joining registry).
- **E5.2 Target selection:** from E0 Run-B — evaluators hot in generic rows whose
  sites report multi-member joined sets (E0.5 data). Start with ≤ 5 globals.
- **E5.3 Gates:** spec-count/binary-size/compile-time budgets recorded per target;
  corpus green flag-on; byte-compare vs the JS-hosted compiler at the same config
  (genuineness protocol); E0 re-census (target sites become singletons → stamped).
- Known cost model: keyed adds ~28% mono time when GLOBAL — per-global keying
  should be near-free; measure and record.

## 11. E6 / E7 / E8 (design-first outlines — unchanged from v1)

- **E6 — per-set cloning post-mono** (pairs with A1; the solver-free fan-out):
  first step is a design doc reviving H5's "closure-parameter worker cloning" with
  the H5 risk ledger (staging revalidation via `validateClosureStaging` on the
  mutated graph, statepoint-pressure caps, budget). Do not start before A1 GO +
  an E5-class prize confirmed by E0.
- **E7 — staging retirement dividend:** trigger = E0's `wrappersInserted` (already
  reported, `Builder/Generate.elm:917`) colliding with stamped sites on hot paths.
  First step is its own design doc (§9.4 ladder; the GOPT_003 relaxation variant
  is explicitly separate).
- **E8 — borrow seeding (M6 handshake):** LSS-side deliverable = a stable
  `LSet`/`srcLambda` query API over the post-GlobalOpt graph for borrow summaries
  (`design_docs/globalopt/borrow-inference-design.md` names LSS facts as its
  precision upgrade). Build when the borrow plan reaches its LSS-consuming
  milestone. Note A1.0 (`srcLambda` under subst) is also a prerequisite HERE —
  another reason A1.0 lands early regardless of the spike's outcome.

## 12. A-track side items (not phases of this plan)

- **A2 — cheapen the solver** (owned by `plans/monosolver-*`): pretenuring/nursery
  policy for long-lived UnionFind/IORef state (≈248 s minor GC), `S`-record
  splitting (32-slot GC scan limit, `Engine.elm:204–208`), hottest-path
  de-allocation. Root-cause the Stage-8a warm-cache anomaly (solver 5.17×) before
  any engine-default flip. A1 makes all of this non-blocking for exploitation.
- **A3 — policy note (zero code):** "LSS on optimized builds only" is expressible
  with existing config; write it down once something ships.

## 13. Standing verification discipline (applies to every gate)

- Test suites ONCE: `<cmd> 2>&1 | tee /tmp/test_output.txt`, then grep/head/tail
  the file. Never re-run for different views.
- `find /work/test -name "*.elm" | xargs touch` before ANY corpus gate under
  changed flags/config (harness compile cache is mtime-only and env-blind). Never
  wipe individual build dirs.
- Censuses: native AOT only, manual runs from `/work/build/compiler/build-kernel`
  (harness swallows census stderr); fresh eco-stuff per configuration; sort logs
  before the symbolizer; 3–4 repeats; stats-on AND stats-off for any stability
  claim.
- Wall-clock: interleaved A/B ×3 per side (±3–5 s drift); record backend tier on
  every number (Dev tier does not inline — E1.1).
- Every knob that changes front-end artifacts joins the config hash
  (`lssl=`, `lssKG=`, `maxDispatchArms` when non-default). Report-only envs
  (`ECO_MONO_LSS_SITES`) and lowering-time envs (`ECO_LSS_DISPATCH_SITE_COUNTERS`,
  `ECO_DISPATCH_STATS`) stay out of the hash but are census-workflow-only.
- Every new optimization ships targeted adversarial tests that fail if it breaks
  while the flag-off-shaped corpus stays green (LSS 3.6 lesson).
- Solver-route gates: genuineness protocol (explicit-compile byte-compare vs the
  JS-hosted compiler at the same config).
- Don't run `build/test/test` and `elm-tests` concurrently (typed-artifacts race).

## 14. Invariants delta

- E0: none (env-gated).
- E1: none (lowering form change; CGEN_CLOSURE_005 unchanged).
- E2: **LSS_011** (PAP-prefix stamp discipline — §6/E2.5).
- E3: **LSS_012** (set-dispatch stamp discipline + default arm — §8/E3.5) + CGEN
  sibling for the switch lowering; delete the `_dispatch_mode` rows if any exist.
- E4c: CGEN_CLOSURE_005 extended to i16 captures.
- A1: LSS_001/002 now apply to Lite-annotated graphs; note in LSS_003 that
  `srcLambda` threading is engine-independent after A1.0.
- E6: FLAT_001–003 revived (own design doc).

## 15. Non-goals / falsified (do not rebuild)

- M5 tagged capture unions (H7 NO-GO stands; E3 takes the dispatch value without
  the representation; revisit conditions in `capture-union-representation.md` §5).
- Runtime fast paths in generic apply (capability bit) — static routes first.
- U2b-style spec-level arity raising — falsified on wall-clock (disposition §15.1).
- H5-v2 variable-arg loopification as previously scoped — superseded by E5/E6.
- Allocation-count-driven prioritization of any of the above.

### 15.1 U2b (`ECO_ARITY_RAISE`) code disposition — keep flag-off, two dated triggers

The raiser is crash-free, byte-identical flag-off; creates −37.8% / events −13.5%;
the +55% wall penalty was attributed (never profiled) to exactly the dispatch
class E1/E2 attack — the falsification is contingent on today's dispatch costs.

1. **E0 Run C (attribution, ~free):** dispatch census ARM=0 vs flag-off — confirms
   or refutes "the +55% is generic-apply traffic" with data.
2. **Post-E2 (+E1) re-measure:** one interleaved ARM=0 A/B. Wall ≤ flag-off ⇒ U2b
   re-opens as an allocation lever (interesting again in the borrow/RC era).
   Still regressing ⇒ **delete** `raiseStagedSpecs`, `raiseAppliedShareMin`, the
   `ar=`/`arm=` hash tokens and flag-on probe pins in one commit; close the item.

No new investment meanwhile; flag-on is not CI-covered — if the E-track stalls
past E2, prefer deletion over silent rot. The unconditional fixes U2b surfaced
(cross-stage emission guard, first-stage beta split, destructure-binder
freshening, `eco_pap_extend` kind conversion, two kernel GC use-after-frees) are
default-path and stay regardless. The call-site-level raising variant is a
separate research note and shares little code with the per-spec raiser.

## 16. Open questions (answered by E0/A1)

1. How many generic-apply events does the native self-compile execute
   (Run A), and what fraction is addressable (Run B split)?
2. Do the existing ~3,140 stamps carry dynamic weight (fast rows), or did
   inlining already eat Channel B's hot sites?
3. Is the PAP-under-saturation bucket (E2's target) dispatch-hot post-P6?
   **Statically answered by E0.5** (6,801 sites = 99.2 % of declines); dynamic
   weight is measured by the post-E2 re-census (hot rows are `LTop`, so expect a
   bounded gain — E2.−1).
4. Can A1's DSU inference match unkeyed solver-LSS singleton counts — globally
   and on E0's hot sites? Which precision-gap classes appear (data-stored arrows
   are the expected one)?
5. Are hot `$cap` bodies inlined at -O2 (E1.1), and what does the Dev tier's
   no-inliner policy cost in day-to-day measurements? (Separate decision:
   whether Dev should gain a cheap inliner.)
6. Does `wrappersInserted` collide with stamped sites on hot paths (E7 trigger)?
7. E2.0(3): what exactly do `n_values`/`max_values` hold for captures-bearing
   closures? **SETTLED** (E0 code read of `eco_closure_call_saturated`'s
   `combined_args = alloca(max_values)` + splice semantics): `max_values` =
   |captures| + |params| (total evaluator slots), `n_values` = filled slots. One
   residual pin on the papCreate lowering's header packing remains in E2.0(3).
