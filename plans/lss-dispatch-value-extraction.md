# LSS Dispatch Value Extraction

**Status:** v2 (2026-07-16) — implementation-ready refinement of the v1 outline.
Phases E0/E1/E2/S are specified to step level (A1 was removed 2026-07-17, replaced
by S — §7); E3/E5 to step level with an explicit
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
  (`Specialize.elm:1502, 1787`) — only relevant if borrow (E8) ever consumes
  subst graphs (was A1.0; A1 itself removed, §7).
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
              ├─ join-widened hot HOFs? ──→ E5 (solver route, after S)
              └─ wrappers collide with stamps? ──→ E7 (design first)
S (spine injection, §7) ── activates E2's suffix arm + grows the consulted set;
                           re-read the census/histogram after it before E3/E5 calls
```

E0 → E1 → E2 (+E4c) are unconditional-order; **S follows E2** (it is E2's
activation). E3/E5/E7 are data-chosen post-S. E8 is externally scheduled
(borrow plan). A1 was REMOVED 2026-07-17 (see §7's decision note) — lambda-set
work stays solver-side; there is no subst-side set implementation to align.

**Gate verdicts as of 2026-07-16 (from E0/E1 results, details in §4/§5):** E0 DONE
(Run A 922.3 M dispatches; Run B coverage 1.75 %/3.52 %; stamped ≠ hot; 89.3 % of
arrows `LTop`). E1 audit DONE — devirt already works, inlining is the gap (E1.3),
payoff scales with coverage → do E1.3 with/after a coverage phase. **E2 GO** (gate
met, §6/E2.−1). **E3 deprioritized** (multi-sets = 0.8 % of arrows). **S (spine
injection, §7) is the next build** — it attacks the analysis-side ceiling
directly and activates E2; E5 follows it; E8 external. The hot-dispatch ceiling
is analysis-side (trivial signatures + escape-to-data soundness), not
mechanism-side.

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
- **(Superseded note:** the A1 post-mono re-inference idea recorded here was
  removed 2026-07-17 — the 89%-LTop ceiling is attacked solver-side by spine
  injection, §7.)

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
latent staging-emission defect; E2 neither causes nor masks it.
**ROOT-CAUSED (2026-07-16, engine-INDEPENDENT — reproduces under plain subst
with a real module, `caseFunc 0 5 3` over differently-staged case lambdas):**
in `applyByStages` (`Expr.elm:~2016–2051`), later-stage batches recurse with
`callKindAttr = Nothing`, but the H6.2-Layer-1 `segmentation_unknown`
downgrade lives only inside the `Just ck` arm — dead code, since the first
batch is never cross-stage and later batches are always `Nothing`. Cross-stage
batches therefore emit NEITHER attribute. Consequences: (a) the CGEN_052
checkers flag them (the 4 elm-tests failures, present since Layer 1 landed
Jul 15 — elm-tests were not re-run at HEAD after it); (b) a real (small)
runtime cost: attr-less generic extends lower via `lowerGenericApply` (boxes
primitives) instead of Layer 1's intended `lowerSegmentationUnknown` (typed
buffer, no boxing — CGEN_060's explicit no-boxing mandate for this shape).
**FIXED (2026-07-16, test-first):** the E2E pin
`test/elm/src/CrossStageCallKindTest.elm` (`-- CHECK-MLIR: segmentation_unknown`
+ `-- CHECK: result: 8`) reproduced the bug in the harness
("MLIR-shape check failed: Missing pattern") BEFORE the fix; the 6-line hoist
(`callKindAttrs = if isCrossStage then [("_call_kind","segmentation_unknown")]
else case callKindAttr of …`) then flipped it green. Gates: full E2E
**1621/1621** (touch-all — genuine recompiles under the changed emission);
elm-tests **12991/12 — the exact known baseline restored** (all four papExtend
invariant failures flipped green; the 12 remaining are the old tvar-scoping
family). Cross-stage batches now lower via `lowerSegmentationUnknown`
(typed buffer, no primitive boxing) as Layer 1 intended. NOTE: contrary to
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

### E2.7 — v2 STAGED STAMPING (designed 2026-07-18; implementation-ready)

**Why now (Run F's mandate).** The Over class is the largest and hottest
unconverted bucket: 6,817 singleton over-apply sites UNKEYED at self-compile
scale (`declinedShapeArityOver`), +88 more when keying (Run F) — and the hot
IO-continuation dispatch (`f a state1` on `f : a -> IO b`, where `IO b` is a
state FUNCTION) lives exactly here. v1 declines any site applying more args
than its callee type's first stage. v2 converts the FIRST stage of such a
site to a fast direct call and applies the remainder generically.

**Semantics (LSS_014).** At an over-apply site with singleton `{m}` whose
callee-type FIRST stage matches an instance of m exactly (params + return,
layout-wise), the runtime callee IS that instance (LSS_009), so applying the
first `|inst.paramTypes|` args saturates the instance's own stage — the same
truthfulness contract as the v1 exact stamp (`remaining_arity =
|inst.paramTypes|`, the instance's own shape; CGEN_052 satisfied). The
intermediate result (the instance's staged return — a runtime-computed
closure) then receives the REMAINING args through the generic
segmentation-unknown path — precisely the H6.2-L1 cross-stage doctrine
("a batch past the first stage boundary extends a runtime-computed value").
v2 converts dispatch #1 of the chain; later-stage dispatches stay generic
(chaining them needs per-stage result-set reasoning — v3, census-gated).

**Resolution (`AbiCloning.elm`).**

1. `Resolution` gains `StampStaged Instance`.
2. `resolveRepresentative`'s Over arm (`:1096-1097`) stops declining blindly:
   `argCount > |fargs|` → scan `Dict.get (siteFingerprint fargs fret) buckets`
   with the EXACT-path group test minus the argCount equality
   (`g.paramCount == |fargs| && eqLayoutLists g.rep.paramTypes fargs &&
   eqLayout g.rep.returnType fret`), gated `g.charFree` (captures load the
   same i16-gated path) and `g.unanimous`; hit → `StampStaged g.rep`; any
   miss → `Decline bumpShapeArityOver` (census bucket preserved). NO PAP
   fallback in the staged arm (an over-applied PAP is v3; `fastPapPrefix`
   stays `Nothing` on staged stamps).
3. `stampCall`'s `StampStaged` arm stamps the SAME fields as exact `Stamp`
   (`closureKind`, `captureAbi` = the instance row verbatim, `fastEvaluator`)
   and bumps a NEW `stampedStaged` counter (add to `AbiCloningStats`,
   `emptyStats`, and the `Builder/Generate.elm` census line). No new CallInfo
   field ⇒ the S.11 phase-5 preservation copy needs NO change (emission
   detects stagedness as `|args| > |captureAbi.paramTypes|`).

**Emission (`Expr.elm`).**

4. New `fastDispatchStampStaged callInfo args`: `Just (lid, abi)` iff
   `fastEvaluator`+`captureAbi` present, `fastPapPrefix == Nothing`,
   `not (List.isEmpty abi.paramTypes)`, and
   `List.length args > List.length abi.paramTypes`.
5. New `generateStagedFastDispatchCall ctx func args resultType lid abi`:
   `batch1 = take |abi.paramTypes| args`, `rest = drop …`;
   (a) emit batch 1 via the EXISTING `generateFastDispatchCall` with
   `resultType = abi.returnType` (its papExtend claims
   `remaining_arity = |paramTypes|` and returns
   `monoTypeToAbi abi.returnType` = `!eco.value`, an arrow);
   (b) apply `rest` to the batch-1 result var with ONE generic
   `eco.papExtend` carrying `_call_kind = "segmentation_unknown"` and NO
   `remaining_arity` (runtime drives multi-stage saturation from the closure
   header — the same op shape `generateUnknownSegmentationCall` builds;
   factor its op-builder core into a var-level helper), then coerce to the
   site's expected ABI result.
6. Consult points: extend the two existing stamp consults
   (`CallGenericApply`, `CallSegmentationUnknown` arms of `generateCall`) with
   the staged fallback, and add BOTH consults at the top of the
   `CallDirectKnownSegmentation` arm (multi-stage dispatched calls route
   there and today never consult the stamp at all — DISCOVERED GAP: only
   1,571 `singleton_fast` ops emit from 2,397 v1 stamps; the multi-stage-
   routed remainder is silently dropped at emission. The added consult also
   recovers any EXACT stamps routed there). `CallDirectFlat` (kernels) is
   never stamped — untouched.

**What v2 must NOT do.** No stamp when the first-stage layouts mismatch
(different specialization — decline); no staged+PAP combination; no touching
`applyByStages` internals (the tail is one generic op, not a batch chain —
segmentation-unknown is always correct and the runtime already owns
cross-stage segmentation).

**Pins & gates (E2.7).**

- Unit pin `E2V2StagedDispatchTest`: curried lambda literal
  (`\a -> \b -> a*10+b`) into a NON-TAIL recursion-guarded HOF
  (`applyStaged f n acc = if n <= 0 then acc else f 10 (applyStaged f (n-1)
  acc)` — non-tail to dodge H5 loopification, the E5-pin lesson), site
  `f 10 …` applies 2 args over a 1-param instance. RED today
  (`declinedShapeArityOver`), GREEN after: some call has
  `fastEvaluator /= Nothing` AND `|args| > |captureAbi.paramTypes|`.
- E2E runtime test `test/elm/src/StagedFastDispatchTest.elm` (result CHECK
  only — no CHECK-MLIR: the default corpus runs flag-off where no stamp
  exists).
- elm-tests baseline; solver+LSS native self-compile — THE gate (thousands
  of sites activate at once; watch for S-class materialization/verifier
  fallout); flag-off byte-identity + flag-on corpus via the A/B legs.
- Run G benchmark: census (`stampedStaged` ≈ thousands, `declinedShapeArityOver`
  drop, `dispatchUpgraded` recovery from the consult gap), sizes/walls,
  subst byte-identity, and the DYNAMIC coverage A/B — the first run where
  `fast` is expected to actually move (the IO rows). Optional keyed leg
  (E5+v2 compose: the +88).

Effort: M. Risk: MEDIUM — thousands of first-activation stamps at scale;
bounded by the fences (first-stage layout equality, charFree, unanimous,
blocked) and caught by the self-compile gate.

**AS BUILT (2026-07-18) — SHIPPED; first E-track phase to move the dynamic
needle: coverage 1.75 % → 5.37 % (Run G).** Implemented exactly as designed;
all gates green FIRST TRY (pin RED/GREEN-proven; elm-tests 12997/12;
solver+LSS self-compile clean with the stamps live; flag-on corpus 1622/1622
incl. `StagedFastDispatchTest`; subst byte-identical). Static: 344 of 6,817
over-apply sites stamp unkeyed (5 % — the first-stage layout equality is the
filter; the 6,472 residue misses the bucket), +35 more keyed (the E5
compose, Run F's +88 partially converting). Dynamic: those 344 sites carry
33.8 M dispatches/run — `fast` +207 %, `sat` down by EXACTLY the same
(1:1 conversion), wall −1.6 % (directional). The hot-site prediction held:
the staged class WAS the IO-continuation weight. Remaining in census order:
ctor instances (`List.cons`, ~15 % of dispatch), per-member attribution of
the 6,472 residue, v3 later-stage chaining, E1.3 inlinehint (now on 50 M
fast calls). NOTE the emission-gap recovery (`CallDirectKnownSegmentation`
consult) is part of the dynamic gain — placement census unchanged (2,399),
emitted-op census is what moved.

---

## 7. S — Spine injection: lambda sets on inner arrows (REPLACES A1)

**Decision (2026-07-17):** A1 (post-mono "LSS-Lite" on the subst graph) is
REMOVED from the plan. Rationale: it would have been a THIRD lambda-set
implementation, bolted onto the engine whose recorded-types layer is the one
with documented completeness doubts (the 12-test analysis, §history in memory),
while the principled engine sits unused — exactly the divergence the project
does not want. The one thing A1 uniquely promised — member transport to
inner-arrow (partial-application) types — is available INSIDE the solver for
less work, through machinery that already exists: this section. The solver
remains the single source of truth for lambda sets; subst never had them, so
nothing needs aligning.

**Design in one line:** v1 injects a lambda's member id into the set slot of
its type's HEAD arrow only (`injectHeadMemberId`, one-slot write); change it to
write the member into **every arrow slot along the type's result chain** (the
"spine"), and ordinary call unification transports the fact to every
partial-application site for free — because in the store, a partial
application's result Point IS the callee type's inner-arrow Point.

**Why transport is free (the premise, verified):** `Unify.elm:727–749`'s
`FunL × FunL` arm does `subUnify res1 res2` and `subUnify set1 set2` — when
`translateCall` unifies a callee `f : FunL a (FunL b c)` against
`FunL argVar resultVar`, the call's `resultVar` MERGES with the inner
`FunL b c` Point. Any member sitting on the inner arrow's slot is then simply
*there* at every downstream use of the partial application (`let g = f 10`,
g passed around, g applied). No new transport machinery; the M3-era transport
fixes (`demandUnifyRoot`, `argUnifyVar`) keep doing their jobs unchanged.

**Why it is sound (the OQ4 rule, promoted to an invariant):** the design
already states "PAP results keep the underlying callee's member" (design §3.3,
OQ4) — a partial application of m IS m, one stage further in. Inner arrows can
also receive OTHER members through joins (two functions unified at an if/case
or a shared spec): set unification is a total JOIN (`LambdaSet1 × LambdaSet1` =
union), so extra inhabitants widen the set rather than corrupting it —
singleton consumers simply decline non-singletons, exactly as today (LSS_005).

### S.0 Premise pins (write these tests FIRST — they fail today, flip after)

1. **Unit (TestLogic, flag-on):** a SourceIR fixture of the
   `HofPapPrefixDispatchTest` shape (capture-carrying 2-param lambda literal →
   recursion-protected HOF; inside, `let g = f 10` used TWICE, `g x + g 1`),
   run through `TestPipeline.runToGlobalOptLssOn`
   (`tests/TestLogic/TestPipeline.elm:356`) and then MLIR generation; a checker
   in the `PapExtendArity` style walks the emitted ops and asserts a
   `eco.papExtend` carrying `_call_kind = "singleton_fast"` AND
   `_pap_prefix = 1` exists (the E2 stamp firing). This is the AUTOMATED
   flag-on activation pin the E2 phase could not have (unit level — the E2E
   harness sets no env, but TestLogic runs flag-on in-process).
2. **E2E (manual gate step):** `test/elm/src/HofPapPrefixDispatchTest.elm`
   compiled with `ECO_MONO_ENGINE=solver ECO_MONO_LSS_REPORT=1` (via
   `node /work/compiler/bin/index.js make --optimize … --builddir=<name>` from
   `test/elm/`) reports `stampedPapPrefix=2` on the `lss globalopt:` line —
   its doc comment already names this as the activation criterion. Runtime
   output stays `result: 22564` under BOTH engines (LSS_005).

### S.1 The code change (`Compiler/MonoSolver/LssInfer.elm`)

Replace `injectHeadMemberId` (`LssInfer.elm:848–861`) with a spine walk.
Recursion template = `Store.poisonGo` (`Store.elm`, directly below
`poisonArrowSets:~690`): worklist-free linear descent with a Point-keyed seen
set (defensive — `loadTypeC` expands `TAlias` at load (`Store.elm:189–193`),
so mono stores are alias-free in practice, but chase `IO.Alias` anyway and
guard cycles the way `poisonGo` does):

```elm
{-| LSS_013 (spine injection): a member id names not just the value's own
head arrow but EVERY arrow along its result chain — a partial application
of m is still m (OQ4). The store shares result Points with inner arrows
(Unify FunL arm: subUnify res1 res2), so writing the member on the whole
spine makes ordinary call unification transport it to every
partial-application site. Seen-set mirrors poisonGo (defensive; store
structure is finite and alias-expanded at load).
-}
injectSpineMemberId : Int -> IO.Variable -> Step ()
injectSpineMemberId mid v0 s0 =
    spineGo mid Dict.empty v0 s0


spineGo : Int -> Dict.Dict Int () -> IO.Variable -> Step ()
spineGo mid seen v s0 =
    let
        key =
            Engine.pointKey v
    in
    if Dict.member key seen then
        Ok ( (), s0 )

    else
        let
            ( store1, desc ) =
                UF.get v s0.store

            s1 =
                { s0 | store = store1 }
        in
        case desc.content of
            IO.Structure (IO.FunL _ res slot) ->
                case Store.unifySlotWithSet False [ mid ] slot s1 of
                    Err e ->
                        Err e

                    Ok ( _, s2 ) ->
                        spineGo mid (Dict.insert key () seen) res s2

            IO.Alias _ _ _ real ->
                spineGo mid (Dict.insert key () seen) real s1

            _ ->
                Ok ( (), s1 )
```

Notes for the implementer:
- `Store.unifySlotWithSet False [mid] slot` (`Store.elm:680–688`) is the
  existing total-join write — reuse it verbatim per slot.
- `Engine.pointKey` is what `poisonGo` uses for its seen set — same here.
- Do NOT descend into ARGUMENT positions (`FunL a …`'s `a`): an argument arrow
  is inhabited by the *caller's* values, not by m. Result-chain only.
- `IO.Structure (IO.Fun1 _ _)` (slotless arrow) should be unreachable lss-on;
  treat as stop (the `_` arm covers it).
- Imports: LssInfer already uses `UF.get`, `Store.arrowSetSlot`,
  `Store.unifySlotWithSet`, `Engine` — no new imports beyond what
  `injectHeadMemberId` uses plus `Dict` (already imported for memo tables).

### S.2 Call-site audit (one helper, three routes — all switch at once)

Every member injection routes through `injectHeadMemberId` today (grep
verified 2026-07-17):

| caller | anchor | what it injects | switch? |
|---|---|---|---|
| `injectLambdaMember` | `LssInfer.elm:135–142` | source lambda's member into the lambda's own loaded type (from `classifyLambdaHead`, `Translate.elm:1383–1416`, AND from `injectArgLambdaMember`, `Translate.elm:2409` — lambda literals as call args) | YES — rename call to `injectSpineMemberId` |
| walk arm (standalone function values) | `LssInfer.elm:842` | interned member (`"g|" / "c|" / "k|" / "a|"`) for a global/ctor/kernel/accessor used AS A VALUE | YES — a partial application of a global is that global's PAP (OQ4 verbatim) |
| `applyFacts` | `LssInfer.elm:204–207` | signature facts per arrow ORDINAL | NO — already per-arrow (LSS_006 ordinals enumerate inner arrows too: `loadTypeC` accumulates `arrowSlots` per `TLambda`, `Store.elm:137–155`) |
| `poisonArrowSets` | `Store.elm:~690` | ⊤ on kernel/port boundaries | NO — already recurses everything (LSS_004); poison-after-inject is safe (⊤ absorbs) |

Delete `injectHeadMemberId` after the switch (grep must come back empty) so
no future caller reintroduces head-only injection silently.

### S.3 Semantics — invariant delta

New **LSS_013**: *"A member value's type carries its member id on EVERY arrow
of its result spine (head arrow and each nested result arrow), or ⊤: a partial
application of member m is m at the next stage (OQ4), so consumers reading any
peeled arrow of an m-derived value see m in the set or an honest ⊤. Injection
sites: `injectSpineMemberId` (source lambdas via `classifyLambdaHead` /
`injectArgLambdaMember`; interned global/ctor/kernel/accessor values via the
LssInfer walk). Argument-position arrows are NOT injected — they are inhabited
by callers' values."* Add to `invariants.csv`; LSS_001/002/004/005/006/010 are
unchanged in wording and force (spine injection only ADDS members, and the
LSS_002 checker's condition — head anno contains `srcLambda` or is LTop —
still holds a fortiori).

### S.4 What must NOT change (verified no-ops — do not touch)

- **Encode/readback:** `Store.monoTypeToVarC` already encodes each nested
  `MFunction` layer's own anno; `zonkSetSlot` already reads each arrow's own
  slot (design §6.1/§6.3). Inner annos flow into MonoTypes mechanically.
- **Keys:** unkeyed `enqueueSpec` widens sets in keys (`Mono.widenSets`) —
  registry/spec identity untouched flag-on-unkeyed; flag-off mints no slots at
  all → subst byte-identity is structural.
- **EngineDiff:** forces lss-off (design §5.4) — unchanged.
- **Staging/AbiCloning ordering, LSS_008/009 blocker semantics:** unchanged —
  the value flowing at a PAP site is a runtime PAP of m (evaluator = m's
  clone), not a wrapper; wrapper multiplicity still declines via `blocked`.

### S.5 Interactions and honest expectations

- **E2 goes live.** PAP sites become consulted; the E2 suffix arm (`StampPap`)
  is the consumer — its fences are now load-bearing in production: the
  staged-return decline (proven live on the `f 10` probe), charFree, abiKey
  unanimity. Expect `stampedPapPrefix > 0` and `bucketMiss` to grow (consulted
  sites that decline for real reasons) — both are the point.
- **More multi-member sites too.** Inner arrows at joins union more members →
  `LSet [k≥2]` populations grow; `stampCall` ignores them (v1) — this is
  E3-sizing data, re-read the set-size histogram after landing.
- **Solver mono time may rise.** Two channels: (a) `sigTrivial` fast-path
  erosion — today ALL 8,673 signatures are trivial (C2a report), so `lssFast`
  short-circuits everywhere; spine facts can make signatures non-trivial,
  disabling the M2a/M2b fast paths at their call sites (design §8.4); (b) more
  set-slot unifications per lambda (arity-many instead of 1). GATE: solver
  Stage-7a self-compile wall (C2a protocol) before/after, budget ≤ +5% or
  explicit sign-off with the census win recorded alongside.
- **What this does NOT unlock (say it in the gate report):** `List.cons`-class
  ctor members (no `MonoClosure` instance → `declinedNoInstance`; stamping
  ctors is separate future work) and the escaping IO-bind continuations
  (`LTop` by soundness — they enter data structures; that is E8/borrow
  territory). The addressable class is lambda-origin and interned-global
  partial applications — `applySubstPure`/`typeEncoderS`-shaped HOF-arg sites
  from the census. The census delta, not a prediction, is the payoff number.

### S.6 Tests (beyond the S.0 pins)

- **Join fixture (multi-member correctness):** two DIFFERENT lambdas reaching
  one inner arrow (if/else producing partial applications of two lambdas) —
  no stamp (non-singleton), output correct. Guards against any consumer
  assuming singleton-ness of inner annos.
- **Kernel poison unchanged:** a lambda passed to a kernel HOF (`List.map2`
  class) stays ⊤ on the whole spine (LSS_004 fixture exists — re-run flag-on).
- **`LssSharedSpecJoinTest` / `RaiseProbe` / existing `Lss*` pins:** must stay
  green (LSS_010 join now carries inner annos — mechanical, but pinned).
- **LSS_002 integrity checker** (`TestLogic/Monomorphize/LambdaSetIntegrity`):
  green as-is; optionally extend to assert the LSS_013 spine property on
  reachable closures (nice-to-have, not a gate).
- **Adversarial GC variant:** the S.0 fixture under tiny-nursery
  `ECO_HEAP_VALIDATE` (stamped PAP dispatch across a GC point).

### S.7 Gates (in order)

1. S.0 pins written and RED (they fail before the change — proves they bite).
2. Change lands; S.0 pins GREEN; full unit suite `elm-tests` at its known
   baseline (no new failures beyond the documented set).
3. Default corpus: `--target full` green; subst Stage-7a output byte-identical
   (structural — no slots minted lss-off; one run, compare size/hash).
4. Flag-on corpus: touch-all + `ECO_MONO_ENGINE=solver` `--target full` green.
5. Solver self-compile (C2a protocol): report deltas recorded —
   `dispatchUpgraded` / `stampedPapPrefix` / decline mix / set-size histogram;
   solver wall within budget (S.5).
6. Census (Run-D, runtime-calls.md methodology): solver-built binary lowered
   with `ECO_LSS_DISPATCH_SITE_COUNTERS=1`; **coverage = fast/(sat+fast) is
   the payoff number** vs Run B/C's 1.75%/3.52%. Append the run + summary row.
7. Genuineness: byte-compare the native flag-on self-compile against the
   JS-hosted compiler at the same config (established protocol).

### S.8 Effort / risk / order

Effort: S (the change) + M (gates/census). Risk: LOW-MEDIUM — additive facts
through proven join machinery; the two real risks are solver mono-time (gated,
S.5) and consumer assumptions of head-only injection (covered by the join
fixture + the fences E2 already shipped). Execution order:
S.0 pins → S.1/S.2 change → S.6 fixtures → S.7 gates 2–7.

### S.9 AS BUILT (2026-07-17) — the transport is a THREE-link chain; spine is one link

Implemented and unit-gated (elm-tests baseline-identical, 12/12 known failures
unchanged, no new). But a live trace of the canonical PAP shape
(`applyPartial f n acc = … let g = f 10 in g acc + g 1`, HOF called with one
lambda literal) established that spine injection ALONE does not activate E2 —
it is **one necessary link of three**, and my original "shortest path to E2
firing" framing was over-optimistic:

1. **Spine injection (S.1, DONE, correct).** `injectSpineMemberId` writes the
   member on every result-spine arrow. VERIFIED: `f 10`'s callee arrow carries
   `LSet [m]` (the inner arrow got the member). Pin: `SpinePapDispatchTest.elm`
   RED head-only / GREEN spine.
2. **Indirect-call-result transport (companion, DONE, correct).** Found that
   `translateIndirectCallBody` classified the call RESULT storelessly (`LTop`),
   dropping the callee's inner-arrow set at the call boundary — `Store.loadType`
   re-mints fresh LTop slots (LSS_006), so the set had to come from the already-
   translated `Mono.typeOf monoFunc` (which carries it). Fix: `indirectResultAnno`
   overlays the peeled callee annotations onto the classified structure (gated on
   `lss.enabled`; flag-off passthrough → byte-identical). VERIFIED: `let g = f 10`'s
   DEFINITION now carries `LSet [m]` (diag `letdefs=LSet[0]`).
3. **Local-multi USE transport (E4a, NOT DONE — the remaining co-requisite).**
   `g` is a FUNCTION-typed let → `translateLet` routes it to
   `translateLocalMultiLet`; its USE sites (`g acc`) are classified independently
   of the def (`classify meta.tipe` = `LTop` on the `isLM` path,
   `Translate.elm:335`), per the design §8.4 deferred local-multi gap. So `g`'s
   def carries the set but its USES do not, and E2's suffix arm never sees a
   singleton at the dispatch site (decline = `bucketMiss`; the ONE consulted
   singleton site is `f 10` itself, a PAP-CREATING call whose function return the
   E2 fence CORRECTLY declines). `stampedPapPrefix` stays 0 on this shape.

### S.10 CRITICAL BUG + FIX (2026-07-17) — spine injection MUST be arity-bounded

The first spine implementation walked the ENTIRE result spine of a value's type
with no bound (`spineGo` recursed `res` until a non-arrow). This is UNSOUND for
any value whose type spine is longer than its arity — i.e. a **function-returning
body**: point-free/eta-reduced defs, accessors-as-values, and above all **parser
chomper combinators** (`... -> (State -> ChomperResult)`). For those, the arrows
BEYOND the arity are inhabited by the value's RETURNED closure `q`, not by a PAP
of `m`; stamping them with `m` (a) violates LSS_013's own "PAP of m is m"
justification and LSS_002, and (b) via arg/result store-Point aliasing on
identity-like functions, also stamps ARGUMENT arrows (violating the "argument
arrows never injected" guarantee). The type CANNOT distinguish `add : I->I->I`
(arity 2, both arrows m's) from `weird : I->(I->I)` (arity 1, 2nd arrow is the
return) — only the value's **parameter count** can.

**How it surfaced — and what did NOT catch it.** The flag-on E2E **corpus passed
1621/1621** and the **adversarial review's verify pass returned confirmed:[]**
(it could construct no end-to-end miscompile — the widening machinery rescued
every hand-built shape). What caught it was the **compiler self-compile** (Stage
5, native `eco-compiler` build under solver+LSS): mono crashed
`unify-mismatch: Lambda /vs/ Type:ChomperResult` when a beyond-arity Point,
forced to `{m}`, later unified against the concrete `ChomperResult` return type.
LESSON: **the self-compile bootstrap is a non-negotiable gate for any LSS-set
change** — the corpus is too small/first-order and adversarial verification is
too conservative to expose higher-order-return over-injection. The review's
SOUNDNESS lens (rated `major`, `likely`) was right; its own VERIFY step
under-called it. Trust the self-compile.

**Fix (shipped):** thread the value's arity to `injectSpineMemberId arity mid v`;
`spineGo` carries a `remaining` budget, decrements per FunL arrow (NOT per Alias
— same arrow), stops at 0. Arity source: `List.length params` at the four
lambda-literal sites (`walkExpr` Function/TrackedFunction, `classifyLambdaHead`
via `specializeLambda`, `injectArgLambdaMember`); `standaloneMember` uses
head-only (arity 1) — no local param count, identical to the pre-spine baseline
for named-value forms, sound. Follow-up: thread a global's declared arity to
`standaloneMember` to re-enable standalone-value PAP spine. Pin
`SpinePapDispatchTest` stays GREEN (its `\a b -> …` is arity 2 = full 2-arrow
spine, so arity-bounding stamps both arrows exactly as before).

### S.11 SECOND self-compile blocker (2026-07-17): E2's fastPapPrefix dropped in
### GlobalOpt phase 5 — one-line latent bug, exposed by the first live StampPap

After the S.10 arity fix, the solver+LSS self-compile failed later, at backend
MLIR verification: `'eco.papExtend' op references undefined fast evaluator
'Terminal_Main_lambda_NNNNN$cap'` (uid varies per build). Root cause — found
only after three WRONG AbiCloning-side guards (capture-divergence scan,
StampPap-capturing-decline, value-position materialization scan; censuses
proved each inert) — via **`--text-mlir` ground truth**:

- Spine injection activated the **first-ever live StampPap** (`stampedPapPrefix`
  0→1, on `Round.roundFun`'s rounding-lambda PAP — elm-round's
  `roundFun (\i f -> …) : (Int -> Float -> b) -> …` partially applied inside).
- The StampPap stamp is self-consistent: captureless base, `captureAbi =
  take k params ++ drop k`, `fastPapPrefix = Just k` ⇒ emission computes
  `|captureTypes| − k = 0` ⇒ names the BARE symbol. Safe.
- **But `annotateCallStaging` (GlobalOpt phase 5, AFTER AbiCloning) re-derives
  CallInfo and its stamp-preservation copy carried `closureKind`/`captureAbi`/
  `fastEvaluator` — NOT `fastPapPrefix`** (`MonoGlobalOptimize.elm:1184`;
  `computeCallInfo` re-inits it `Nothing`). Emission then read papPrefix=0,
  computed `1−0 > 0`, chose `$cap` — for a **captureless** lambda that emits
  only its bare symbol ⇒ dangling `_fast_evaluator` symbolref ⇒ verifier
  rejects the module. E2 shipped with this field-drop latent (every prior
  census had `stampedPapPrefix=0` — the arm was dormant); spine tripped it on
  first use.
- **Fix (one line): preserve `fastPapPrefix` alongside the other stamp fields
  in `annotateCallStaging`.** All three AbiCloning guards reverted (wrong
  layer; the stamp was correct — phase 5 corrupted it).

DEBUGGING LESSONS (hard-won): (1) `--text-mlir` exists and turns bytecode
archaeology into direct op reading — reach for it FIRST when the backend
verifier rejects front-end output. (2) `Debug.log` is stripped in `--optimize`
self-compiles — thread diagnostics through census/stats fields instead.
(3) When a census is IDENTICAL before/after a guard, the guard targets the
wrong mechanism — stop iterating there. (4) A dormant-until-now code path
(counter permanently 0) is a red flag: the FIRST activation exercises every
downstream consumer of its outputs for the first time — audit field-by-field
what those consumers preserve.

**Consequence for the plan.** E2 activation on let-bound partials (the common
shape) requires **S + E4a together**. E4a is no longer "census-gated backlog"
(§9) — it is the **direct co-requisite of S**, promoted to the next build after
S. The two ship and benchmark together; benchmarking S alone shows the analysis
propagating sets one link further (call results / let-defs) with NO dispatch-
coverage change (E2 stays dormant until E4a). E4a's fix lands at the local-multi
use/record seam (`translateLocalMultiCall` / `recordLocalInstance` /
`buildLocalDefs`): overlay the def's set onto the per-use recorded instance type
— more entangled than S's overlay (it rides the per-use re-translation
machinery), hence its own design pass. Non-let PAP consumers (a PAP passed
directly as a call arg to a non-inlinable local) may activate without E4a — the
census will say whether any exist at weight.

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

Gate to keep: corpus green (solver route, post-S); census delta on
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
- **E4a — V1 local-multi transport (M): IMPLEMENTATION-READY DESIGN (2026-07-17
  design pass; promoted to S's direct co-requisite by §S.9). See §9.1 below.**
- **E4b — V2 wrapper-home recovery (M–L):** staging-side
  (`chooseCanonicalSegmentation` bias toward singleton-upgradable producers);
  overlaps E7 — build only under E7's gate.

Gate: E0 per-class ranking (H6.0b currently shows zero declines from these
classes; they stay backlog until the census disagrees).

### 9.1 E4a — local-multi USE transport: design (implementation-ready)

**The gap, precisely (verified against the code, not the old §8.4 sketch).**
A function-typed let (`let g = f 10 in … g acc … g 1`) routes through
`translateLocalMultiLet` (`Translate.elm:3994`). Order of events:

1. `pushLocalMulti name` — a registry entry goes on `s.localMulti`.
2. The let BODY is translated. Every use of `g` hits one of two paths, and both
   mint the use's MonoType from a **fresh, per-use instantiation** whose arrow
   annos are all `LTop`:
   - call path `translateLocalMultiCall` (`:1568`): `instantiate funcCanType` →
     unify args → `Store.zonkToMono funcVar` → `recordLocalInstance name
     funcMonoType` → emits `MonoCall (MonoVarLocal freshName instType) …`;
   - value path `TOpt.VarLocal` isLM branch (`:335–348`): `classify meta.tipe`
     (storeless ⇒ `LTop`) → `recordLocalInstance` → `MonoVarLocal freshName
     instType`.
3. `popLocalMulti`, then `buildLocalDefs` (`:4053`): per recorded instance,
   `retranslateAt defBody inst.monoType` (`:3254`) re-translates the RHS **in a
   scratch store** (fresh store/memo/aux, restored after — no Points survive)
   seeded by `demandUnifyRoot`. THANKS TO S (spine + `indirectResultAnno`), the
   re-translated RHS's MonoType **carries `LSet [m]`** (the existing
   `SpinePapDispatchTest` pin proves this on the final graph).

So the def-side set exists only AFTER every use is already emitted with `LTop`,
and in a store that is discarded. **A solver-side def→use Point join is
timing-impossible for local-multi** (unlike LssInfer's signature-walk
`joinLetUse`/`joinArrowSets` §7.4, whose union-over-uses POLICY we mirror). The
correct seam is a **post-hoc annotation overlay on the already-built body**.

**The change (one new helper + one wiring edit, both in `Translate.elm`).**

- `enrichLocalMultiUses : Bool -> List Mono.MonoDef -> Mono.MonoExpr ->
  Mono.MonoExpr` (pure): when the Bool (lss.enabled) is False or the def list
  is empty, return the body unchanged. Otherwise build
  `annoByName : Dict Name Mono.MonoType` from the instance defs
  (`Mono.MonoDef n rhs → (n, Mono.typeOf rhs)`; `MonoTailDef` arm skipped —
  local-multi defs are always `MonoDef`), then rewrite the body with
  `MonoTraverse.traverseExpr` (bottom-up, full constructor coverage incl.
  closure captures/bodies; ctx = ()): each `MonoVarLocal n t` with
  `Dict.get n annoByName == Just src` becomes
  `MonoVarLocal n (Mono.overlayAnnotations t src)`. Everything else unchanged.
- Wiring in `translateLocalMultiLet`: read `s.env.lss.enabled` once (a pure
  state READ — zero store mutation, zero effect order change), and apply
  `enrichLocalMultiUses lssOn instanceDefs monoBody` in the existing final
  `Engine.map` block before the `List.foldl (MonoLet…)` assembly (`:4028`).
  The `classify letCanType` call and all other stateful steps keep their exact
  order — byte-identity is structural flag-off (helper returns the body
  untouched) and unthreatened flag-on (pure rewrite, deterministic).

**Why this is sound.**

- The runtime values reaching a use of `freshName` are exactly the values the
  instance's re-translated RHS produces — the def's lambda-set IS the use's
  lambda-set. Narrowing the use's `LTop` to the def's set is the graph-level
  image of §7.4 `joinArrowSets` (union over uses at one layout; per-layout
  instances get their own re-translated RHS type, so precision is per-instance).
- `Mono.overlayAnnotations` (`Monomorphized.elm:488`) is shape-guarded: on any
  structural mismatch it keeps the use's own structure and falls back —
  worst case is an untransported anno (`LTop`, sound widening; LSS_005).
- Name-keying is safe: Elm canonicalization forbids shadowing, `$`-suffixed
  freshNames cannot collide with source names, and the first instance's bare
  `name` is the unique in-scope source binder. Capture ENTRIES rewrite only
  their expr component (the name field is the inner binder, untouched).
- `eqLayout` ignores annos (`Monomorphized.elm:304` MFunction arm), so the
  enriched use types cannot perturb layout keys, instance dedup
  (`recordMultiInstance`), or `ECO_MONO_VALIDATE`.
- The stamp consumer reads `Mono.headAnno (Mono.typeOf func)` on the callee
  (`AbiCloning.stampCall`); the callee at these sites IS the rewritten
  `MonoVarLocal` — no other consumer of the instType exists post-emission
  (`inst.monoType` is only the `retranslateAt` demand, already consumed).

**What then happens downstream (the activation chain, now fully proven).** A
saturating call `g acc` gets callee head `LSet [m]` → `stampCall` resolves
member m's index (the base lambda's instance, params `[a,b]`) → site layout
`[b]→ret` bucket-misses → `resolvePapSuffix`/`papScan` k=1 suffix-match →
`StampPap inst 1` → captureless base ⇒ `captureAbi = take 1 params`,
`fastPapPrefix = Just 1` ⇒ emission picks the BARE symbol with `_pap_prefix=1`
(the S.11 fix makes the field survive `annotateCallStaging`), and
`emitFastClosureCall` loads the PAP's filled slot + arg row. The whole runtime
path was already exercised once by Run D's `Round.roundFun` stamp.

**V1 scope limits (documented, measured later, not blockers).**

- Callee-head transport only. Chained partial lets (`let h = g 1 in h y`) stay
  `LTop` at h's uses: h's own `buildLocalDefs` runs DURING g's body translation,
  before g's overlay exists, so h's re-translated RHS type misses the set.
  Follow-up (E4a.2) only if the Run-E census says chained partials carry weight.
- No MonoCall-result overlay (only matters for the chained case above).
- Union-over-uses per layout (v1 policy, same as §7.4).

**Pins & gates.**

1. Upgrade `SpinePapDispatchTest`: keep the letdef assertion; ADD the use-site
   assertion — some `MonoCall` whose func is a `MonoVarLocal` with singleton
   `LSet` head — and the STAMP assertion — some call's
   `callInfo.fastPapPrefix == Just 1` (runToGlobalOptLssOn output is
   post-AbiCloning, so the stamp is visible to the unit test). RED before the
   change, GREEN after.
2. Full elm-tests: 12992/12 baseline, no new failures.
3. Native solver+LSS self-compile — THE gate (S.10/S.11 lesson).
4. Flag-off byte-identity + flag-on corpus via the Run-D A/B method.
5. Benchmark Run E: `stampedPapPrefix` census delta (expect ≫1: every singleton
   let-bound-partial site with a layout match), solver-leg wall, subst-leg
   byte-compare; if stamps move at weight, the dispatch-coverage census leg.

Effort: S–M (one pure helper + one wiring line + test). Risk: LOW — pure,
lss-gated, shape-guarded; the dangerous parts (StampPap runtime path, prefix
survival) were de-risked by S.

**AS BUILT (2026-07-17) — SHIPPED, all gates green, activation zero at
self-compile scale (Run E).** Implemented exactly as designed
(`enrichLocalMultiUses` + the `translateLocalMultiLet` wiring; letType kept on
the un-enriched body). Pins: `SpinePapDispatchTest` now 3 tests — letdef
singleton (spine), use-site singleton on the PAP-CONSUMING shape (ground
result, excluding the `f 10` M3-covered site), and `fastPapPrefix == Just 1`;
the last two RED-proven with E4a neutralized. Gates: elm-tests 12994/12
(baseline + the 2 new pins), native solver+LSS self-compile GREEN first try
(S.10/S.11 fixes held), flag-on corpus 1621/1621 incl.
`HofPapPrefixDispatchTest` running its now-live StampPap'd dispatches, subst
legs byte-identical. **Run E: solver MLIR BYTE-IDENTICAL spine↔e4a —
`stampedPapPrefix` stays 1.** The compiler's own code has no
naturally-singleton let-bound partials: a qualifying site needs its HOF param
to carry a SINGLETON set, but per-TYPE demand monomorphization joins all call
sites' lambdas at one type (multi-member/⊤). The transport chain (S links 1–2
+ E4a link 3) is now COMPLETE and waiting; minting singletons is E5's job
(per-call-site keyed fan-out) — re-measure there. E4a.2 (chained partials) —
unmotivated; nothing chained can qualify before E5 either.

## 10. E5 — Selective keyed fan-out (solver route) — IMPLEMENTATION-READY
## (design pass 2026-07-17; every seam verified in code)

**Why this is the next lever (post-Run-E).** S + E4a completed the transport
chain, and Run E proved zero self-compile activation: a let-bound partial (or
any HOF-internal dispatch) stamps only when the HOF's param carries a
SINGLETON set, but specs are demand-monomorphized per TYPE, so a HOF called
from several sites with different lambdas at one type carries the JOIN. E5
keys chosen globals per ANNOTATED type, so each call site's lambda mints its
own spec of the callee — the spec's param set is that site's singleton, and
the dormant E2/exact-Stamp machinery fires inside the specialized body.

**Mechanism already exists.** `enqueueSpecKeyed` (`Engine.elm:604–661`, M4)
does budgeted keying (`maxSpecsPerGlobal`, default 64; over-budget demands
fall back to the widened key and count `widenedByBudget`), and BOTH branches
route through the LSS_010 joining registry (`getOrCreateSpecIdKeyed` — an
annotated key can collide with a widened one when a demand is all-`LTop`;
join-on-hit prevents the shared-spec miscompile). The M3 arg-side injection
(`injectArgLambdaMember`) already puts the call-site lambda's member on the
zonked demand the enqueue receives. NOTHING in the keyed path changes; E5.1
only widens WHO enters it.

### E5.1 Per-global keying (config + env + hash + gate)

1. **Config field** (`Compiler/Eco/Config.elm`): add
   `keyedGlobals : List String` to `LssConfig`, USER format
   `author/project:Module.Name.value` (e.g. `eco/compiler:Terminal.Main.foo`,
   `elm/core:List.foldl`). NOTE the comparable gkey
   (`Mono.toComparableGlobal` = `"G" ++ author ++ NUL ++ project ++ NUL ++
   modName ++ NUL ++ name`, `Monomorphized.elm:1191`) is NUL-separated and
   cannot be typed in an env var — the config stores user format and the
   engine converts. Only TWO construction sites exist: the `defaultLss`
   literal (`:101`, add `keyedGlobals = []`) and the POSITIONAL applicative
   `lssDecoder` (`:263`, add
   `|> D.apply (D.optionalField "keyedGlobals" (D.list D.string) [])` in
   field order). All other sites are record updates — unaffected.
2. **Env override** (`Builder/Eco/Config.elm`, the `applyEnvOverrides` chain):
   `ECO_MONO_LSS_KEYED_GLOBALS=g1,g2` — split on `,`, trim, drop empties;
   REPLACES the config list (mirror `applyLssBudgetOverride:268`). Malformed
   entries (no `:`, no `/` left of it, no `.` right of it) warn on stderr and
   are dropped — dev-knob behavior, mirroring the unrecognized
   `ECO_MONO_ENGINE` handling.
3. **Hash token** (`Compiler/Eco/Config.elm` token builder, `:381–407`):
   `lssKG=<comma-joined SORTED list>` when non-empty (sort normalizes order so
   equivalent configs share artifacts).
4. **Engine plumbing**: add `lssKeyedSet : Dict String ()` to `Engine.Env`
   (`Engine.elm:141`), built ONCE in `initState`
   (`MonoSolver/Monomorphize.elm:203–229`) by parsing each user entry into the
   comparable shape (split `:`; left `/`→author,project; right LAST-`.`→
   modName,name; unparseable → skipped, already warned at Builder level).
5. **Gate** (`Engine.elm:513–518`): the condition becomes

   ```elm
   if s.env.lss.enabled
       && (s.env.lss.keyed
               || (not (CoreDict.isEmpty s.env.lssKeyedSet)
                       && CoreDict.member (Mono.toComparableGlobal global) s.env.lssKeyedSet))
   then enqueueSpecKeyed global monoType s
   ```

   The `isEmpty` short-circuit keeps the empty-config hot path free of the
   per-enqueue `toComparableGlobal` string build (enqueueSpec is hot). With
   the set empty this is behaviorally identical to today on every path;
   flag-off (subst) never reaches it at all.

### E5.2 Target selection (census-driven, with the instance precondition)

**Precondition — instance availability.** A singleton `{m}` stamps only if
member m has a `MonoClosure` INSTANCE in AbiCloning's index. Lambda literals
qualify; CTOR values (`List.cons` passed to `foldr`) and bare global
references do NOT (no MonoClosure in the graph → `declinedNoInstance`, even
keyed). So select HOFs whose hot call sites pass LAMBDAS.

**Procedure:** from the Run-B dispatch census (top `gen` rows = hot
evaluators), map each hot LAMBDA evaluator to the HOF that dispatches it
(the enclosing apply site), filter by the precondition, key ≤5. Known
candidates at self-compile scale: the `TypeCheck.IO` bind/andThen family
(continuation lambdas ARE literals; the state-function monad dispatches the
continuation from the bind-body-returned closure — whether the escape
analysis leaves the capture's set intact is exactly what Run F measures) and
`List.foldl`/`foldr` sites called with lambdas. `List.cons`-as-HOF rows are
NOT addressable (ctor; needs a separate ctor-instance work item).

**Two selection corrections found during implementation (2026-07-17):**

- **Key the transitive HOF CHAIN, not one function.** `List.map` delegates to
  `foldr`, which delegates to `foldrHelper` (where the `fn a acc` dispatch
  lives). If only the leaf is keyed, the shared UNKEYED middle spec re-joins
  every caller's set before enqueueing the leaf — the leaf fans out on the
  JOIN (useless). So: `List.map` + `List.foldr` + `List.foldrHelper` together.
- **Dispatch SHAPE decides stampability, not just the singleton.** The
  `TypeCheck.IO` family dispatches continuations as staged OVER-applies
  (`f a state1` — `f a` yields the `IO b` state-function, then the state is
  applied), which is E2's v1-DECLINED class (`declinedShapeArityOver`, the
  6,802-site census bucket; staged stamping is declared v2). Keying it mints
  singletons that show up as decline-shift, not stamps — include ONE such
  target as v2-evidence measurement, not as a win. Exact-arity dispatchers
  (`foldl`'s `func x acc`, `foldrHelper`'s `fn a acc`) are the stampable
  class. Also note `foldl` is tail-recursive with a saturated closure-param
  call ⇒ lambda-LITERAL callers are already H5-loopified (no dispatch left);
  keying pays only at var/pipeline-closure callers.

**Run-F target list (finalized):** `elm/core:List.foldl`,
`elm/core:List.foldr`, `elm/core:List.foldrHelper`, `elm/core:List.map`,
`eco/compiler:System.TypeCheck.IO.andThen`.

### E5.3 Pins & gates

1. **Unit pin** (`SpineE5KeyedDispatchTest` or extend SpinePapDispatchTest
   family): recursion-guarded HOF (`applyBoth f n acc = if n <= 0 then acc
   else applyBoth f (n-1) (f acc)`) called with TWO different lambdas at the
   SAME type (`applyBoth (\a -> a*2) 2 1 + applyBoth (\b -> b+7) 2 1`).
   Unkeyed: one spec, joined 2-member set, NO stamped call. Keyed on
   `eco/example:Test.applyBoth` (the TestLogic fixture package is
   `("eco","example")`, module `Test`): two specs, each singleton →
   `f acc` exact-Stamps (`callInfo.fastEvaluator /= Nothing`). RED/GREEN by
   keying. Needs a TestPipeline variant `runToGlobalOptLssKeyedOn :
   List String -> …` = `runToGlobalOptLssOn` with
   `{ defaultLss | enabled = True, keyedGlobals = ks }`.
2. Full elm-tests baseline (12994/12).
3. UNKEYED gates unchanged: native solver+LSS self-compile green; flag-off
   byte-identity; flag-on corpus 1621/1621 (corpus runs default config — the
   keyed path is exercised by the unit pin and the Run-F legs).
4. KEYED self-compile (Run F legs): the compiler builds itself with
   `ECO_MONO_LSS_KEYED_GLOBALS=<targets>` — THE gate for keyed correctness at
   scale (per S.10/S.11 doctrine), and the benchmark in one.
5. Optional (M-series genuineness): byte-compare the native keyed artifact
   against the JS-hosted compiler at the same config — run only if Run F
   shows a surprising delta.

### E5.4 Run F (benchmark; two-phase clean method)

Legs (same tree, `rm -rf eco-stuff` each): (a) e5-binary unkeyed solver —
must be byte-identical to the pre-E5 binary's output (the gate change is
inert when the set is empty); (b) e5-binary keyed-on-targets solver — census
deltas (`dispatchUpgraded`, `stampedPapPrefix`, `declinedNoInstance`,
`widenedByBudget`), output size (spec fan-out), mono wall (expect near-free —
the global-keying +28 % was ALL-globals; per-global should be ~zero) ;
(c) subst legs byte-identical. If (b) moves stamps at weight: lower with
`ECO_LSS_DISPATCH_SITE_COUNTERS=1`, run under `ECO_DISPATCH_STATS=1`, and
report the coverage delta on the target rows vs the Run-B baseline. Record
as Run F in `benchmarks/runtime-calls.md`.

Prep (do alongside): fix the stale "JS solver ≥12×/impractical" claims in the
HOF plan §H3 and the monosolver plan — overturned Jul 16 (Stage 5 = 1.79× in
12 GB; the 8h49m keyed blowup was the pre-fix JS solver; LSS_010 churn already
fixed by drain-end coalescing).

Effort: S (E5.1 is ~5 small edits) + M (Run F). Risk: LOW for E5.1 (inert
when unconfigured; the keyed path itself is M4-tested); the EXPERIMENT risk
(keyed self-compile correctness, spec blowup) is bounded by
`maxSpecsPerGlobal` and surfaces in Run F where it belongs.

**AS BUILT (2026-07-17) — SHIPPED + Run F complete; mechanism proven,
targets falsified, next lever identified.** E5.1 landed exactly as designed
(config field + decoder + `lssKG=` hash token + `ECO_MONO_LSS_KEYED_GLOBALS`
env override with malformed-entry stderr warnings + `Env.lssKeyedSet` +
gate). Pins: `E5KeyedDispatchTest` — keyed run mints ≥2 DISTINCT stamped
fast evaluators on a two-lambda fixture, unkeyed run mints 0 (the premise
and the RED proof in one). FIXTURE LESSON: the HOF must be NON-TAIL
recursive — a tail-recursive spec with a saturated closure-param call is
H5-loopified and no dispatch survives to stamp (first fixture draft found
this the hard way; the E4a fixture dodges it by under-applying). Gates:
elm-tests 12996/12; unkeyed self-compile green + byte-identical to e4a;
subst byte-identical; flag-on corpus 1621/1621; KEYED self-compile builds
and runs correctly. Run F verdict (see benchmarks/runtime-calls.md): keying
is free (+0.14 % output, wall noise), +10 static exact stamps, **+88
`declinedShapeArityOver`** (the andThen singletons hit the v1 staged
decline, as §E5.2 predicted), and the dynamic census is IDENTICAL to the
last digit (fast=16,241,234 both; the +10 sites are cold). **Conclusion:
transport (S+E4a) and minting (E5) are both DONE and free; conversion of
the hot classes now needs E2-v2 STAGED STAMPING (the +88 proves keying
feeds it) for the IO rows, and ctor instances for the cons rows. Those two
are the E-track's open items; re-census after either.**

## 11. E6 / E7 / E8 (design-first outlines — unchanged from v1)

- **E6 — per-set cloning post-mono: SUPERSEDED with A1's removal (2026-07-17).**
  Its premise was solver-free fan-out over A1-computed sets; with lambda-set
  work staying solver-side, fan-out is E5 (keyed, solver route). Revive only if
  a solver-independent route ever becomes strategic again; the H5 risk ledger
  (staging revalidation via `validateClosureStaging`, statepoint-pressure caps,
  budget) still applies to any revival.
- **E7 — staging retirement dividend:** trigger = E0's `wrappersInserted` (already
  reported, `Builder/Generate.elm:917`) colliding with stamped sites on hot paths.
  First step is its own design doc (§9.4 ladder; the GOPT_003 relaxation variant
  is explicitly separate).
- **E8 — borrow seeding (M6 handshake):** LSS-side deliverable = a stable
  `LSet`/`srcLambda` query API over the post-GlobalOpt graph for borrow summaries
  (`design_docs/globalopt/borrow-inference-design.md` names LSS facts as its
  precision upgrade). Build when the borrow plan reaches its LSS-consuming
  milestone. Note: solver-produced graphs already carry `srcLambda`/`LSet`
  facts; threading `srcLambda` through the SUBST engine (`Specialize.elm:1502,
  1787` construct `Nothing`) is only needed if borrow ever consumes subst
  graphs — a small standalone item, no longer scheduled here (it was A1.0).

## 12. A-track side items (not phases of this plan)

- **A2 — cheapen the solver** (owned by `plans/monosolver-*`): pretenuring/nursery
  policy for long-lived UnionFind/IORef state (≈248 s minor GC), `S`-record
  splitting (32-slot GC scan limit, `Engine.elm:204–208`), hottest-path
  de-allocation. Root-cause the Stage-8a warm-cache anomaly (solver 5.17×) before
  any engine-default flip. With A1 removed (§7), exploitation is solver-gated,
  which makes this track MORE important, not less — it is now the only route to
  running LSS-exploited builds affordably by default.
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
  (`lssKG=`, `maxDispatchArms` when non-default; S needs no knob — it changes
  flag-on behavior only, and lss-off mints no slots). Report-only envs
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
- S: **LSS_013** (spine injection — member on every result-spine arrow or ⊤;
  argument-position arrows excluded; §7/S.3). LSS_001/002/004/005/006/010
  unchanged in force.
- E6: superseded (FLAT_001–003 revive only with it).

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

## 16. Open questions (answered by E0/S)

1. How many generic-apply events does the native self-compile execute
   (Run A), and what fraction is addressable (Run B split)?
2. Do the existing ~3,140 stamps carry dynamic weight (fast rows), or did
   inlining already eat Channel B's hot sites?
3. Is the PAP-under-saturation bucket (E2's target) dispatch-hot post-P6?
   **Statically answered by E0.5** (6,801 sites = 99.2 % of declines); dynamic
   weight is measured by the post-E2 re-census (hot rows are `LTop`, so expect a
   bounded gain — E2.−1).
4. (Replaced with A1's removal.) After S lands: how much of the 89 % `LTop`
   converts to concrete sets, what does the new set-size histogram look like
   (E3's gate re-opens on it), and what coverage does the Run-D census show —
   does the addressable class (lambda/global-origin partial applications)
   carry real dynamic weight, given `List.cons` (ctor, no instance) and the
   escaping IO continuations (⊤ by soundness) remain out of reach?
5. Are hot `$cap` bodies inlined at -O2 (E1.1), and what does the Dev tier's
   no-inliner policy cost in day-to-day measurements? (Separate decision:
   whether Dev should gain a cheap inliner.)
6. Does `wrappersInserted` collide with stamped sites on hot paths (E7 trigger)?
7. E2.0(3): what exactly do `n_values`/`max_values` hold for captures-bearing
   closures? **SETTLED** (E0 code read of `eco_closure_call_saturated`'s
   `combined_args = alloca(max_values)` + splice semantics): `max_values` =
   |captures| + |params| (total evaluator slots), `n_values` = filled slots. One
   residual pin on the papCreate lowering's header packing remains in E2.0(3).
