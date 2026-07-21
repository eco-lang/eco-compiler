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

### E1.6 AS BUILT (2026-07-21) — the inline-annihilation GC hazard; v1 ships
### the GC-call-free class only

**Why nothing ever inlined (E1.4's question, answered):** the DEFAULT pipeline
order is RS4GC → optimize on EVERY path (serial, and per-partition workers run
RS4GC before their -O2 — EcoBackend.cpp:769-775; the experimental
`rs4gc-after-opt` flag exists but is off pending REP_LLVM_001(a) validation).
Statepointed calls are gc.statepoint intrinsics — no inliner touches them. So
`$cap` inlining is possible ONLY in a pre-RS4GC prepass, which is what
`runCapInlinePrepass` (EcoBackend.cpp) now is: mark + whole-module
AlwaysInlinerPass + attr STRIP afterwards (attrs surviving into the
post-RS4GC worker pipelines would invite the forbidden late inlining).

**The GC hazard that killed the naive versions (bisected to ONE function,
`Terminal_Main_lambda_15194$cap`, IR-dump verified):** capture unpacking at
call sites (typed wrappers, `$clo` wrappers, `emitFastClosureCall`) loads
boxed slots as **i64 + inttoptr** to ptr addrspace(1); the callee body's own
boundary `ptrtoint` then folds with it DURING INLINING
(`ptrtoint(inttoptr(x)) → x`), annihilating the tracked ptr<1> hop. If the
body contains a statepoint (papCreate/allocs/apply), the resurrected raw i64s
are live across it — invisible to RS4GC — and go stale on any GC inside the
body: REP_LLVM_001(a) violated by IR folding, "Pointer below heap base" at
the next evacuation. Three variants (site-coercing direct-call fold;
matching-only; attrs-stripped) all crashed the all-keyed self-compile in
1-4 s while the 1626-test corpus stayed green — small heaps cannot see it;
the self-compile remains THE gate. A signature-coercing LLVM-level fold
(ptrtoint/inttoptr at mismatched sites) is doubly forbidden — it BUILDS the
violation even without inlining pressure; do not reattempt (the guard comment
in EcoBackend.cpp records it).

**v1 shipped:** alwaysinline only bodies that are ≤ ECO_CAP_INLINE_MAX_INSTS
(default 64) AND **GC-call-free** (`bodyIsGCCallFree`: no non-intrinsic,
non-gc-leaf, no indirect calls) — sound by construction (no statepoint in the
body ⇒ the annihilated hop has no liveness gap to fall into). Population at
self-compile scale: 257 bodies / 263 call sites (of 11,557 surviving direct
`$cap` calls). Delta-debug hooks kept: `ECO_CAP_INLINE_DEBUG=1` (marked-set
listing), `ECO_CAP_INLINE_LIST=<file>` (exact-set marking — the bisection
driver that found 15194 lives in the session scratchpad pattern; threshold
bisect T=16 green / T=32 crash localized the band first).

**v2 BUILT (2026-07-21): typed capture loads landed — but the guard CANNOT
lift; a SECOND annihilation class exists.** The three unpack sites
(ProjectClosureOpLowering, emitFastClosureCall, getOrCreateWrapper) now emit
`load ptr addrspace(1)` for boxed slots. Battery: codegen 385/385, corpus
green, guarded self-compile green + output byte-identical, EcoPtrIntVerify
SILENT on the shipping config, multi-hour ECO_HEAP_VALIDATE self-compile leg
clean. But the guard-lifted config STILL miscompiles — second bisection
(base = the 257 GC-call-free bodies, band = 15,465) pinned
`Terminal_Main_lambda_14615$cap` (a State-bind body), IR-verified: the SAME
`ptrtoint(inttoptr(x)) → x` fold fires on INTERIOR boxed-slot idiom pairs —
here a tuple-projection (load i64 + inttoptr) feeding an args-slot store
(ptrtoint + store) ACROSS the body's direct call — so a raw i64 state
pointer crosses the statepoint and a stale pointer lands in the
GC-registered args buffer ("Invalid tag value" at evacuate). Standalone
bodies never fold (nothing simplifies pre-RS4GC); `InlineFunction`'s
SimplifyInstruction folds everything it clones. Capture loads were ONE
producer; projections/args-slots/closure-stores are the rest.

**VERIFIER GAP (recorded):** the unsound config lowers CLEAN through
EcoPtrIntVerify — the fold ERASES the ptrtoint, so REP_LLVM_001(a)'s
"i64 derived from ptrtoint" predicate never matches; the stale i64 comes
straight from a load whose inttoptr consumer satisfies the (b) provenance
allowance. Any v3 attempt needs either a new check class or the barrier
design below (which makes the check unnecessary).

**v3 SHIPPED (2026-07-21) — the real unlock, fully gated:
`plans/fold-proof-boxed-slot-crossings.md` §9 (as-built).**
Opaque gc-leaf cast barriers (`__eco_slot_to_hptr`/`__eco_hptr_to_slot`) at
the `EcoToLLVMInternal.h` slot-crossing helper layer (all 8 role wrappers +
`wrapperLoadArgSlotToValue` ptr<1> branch + the §8 raw-cast stragglers),
stripped to bare casts by `StripEcoCastBarriers` inside `addEcoGCPipeline`
(ONE placement, after RS4GC + before EcoPtrIntVerify, covering all five
RS4GC call sites + JIT + dumps) with a `report_fatal_error` zero-survivors
check; v2's typed loads stay. **THE GUARD IS LIFTED**: `bodyIsGCCallFree`
applies only under `ECO_CAP_INLINE_GCFREE_ONLY=1` (A/B, marks exactly the
old 257) or forced when `ECO_SLOT_CAST_BARRIERS=0` (the unsound combo is
unreachable); `ECO_CAP_INLINE_NO_GCFREE_GUARD` deleted. Gate results:
barriers byte-transparent (60 MB all-keyed binary on-vs-off BYTE-IDENTICAL,
+2.7 % lowering wall); lifted population 15,744 bodies (+15,487 GC-bearing);
100-body culprit-class pre-gate + FULL lift leg both run the all-keyed
Stage-7a rc=0 with output byte-identical (self-compile fixed point holds);
surviving direct `$cap` calls 11,294 → 5,161 (the mismatched-ABI residue);
binary −0.56 %; corpus 1628/1628; EcoPtrIntVerify (validation build) silent
over the lifted IR; bounded ECO_HEAP_VALIDATE leg (tiny nursery, 149
minors + 1 major over 108 M objects) clean. New invariant REP_LLVM_002.
**Run O DONE (2026-07-21, `benchmarks/runtime-calls.md` §Run O):**
interleaved wall A/B ×3 = NEUTRAL (guard 4:28.1 vs lift 4:29.5 mean,
majors 10 all legs); census identical to the last digit; MAX_INSTS sweep
64/128/256 monotone (15,744/18,033/19,247 marked; binary keeps shrinking
to 59.18 MB; survivors 5,183/2,926/1,711 — T=256 residue ≈ the true
mismatched-ABI floor), default stays 64. E1.3 closes as a
correctness/infrastructure win: full population inlines for FREE on the
allocation/GC-bound self-compile; payoff thesis moves to call-overhead-hot
workloads + post-inline optimization (binary −0.55 % already reflects it).
Delta-debug hooks kept: `ECO_CAP_INLINE_DEBUG`,
`ECO_CAP_INLINE_LIST` + the halving driver (two culprits, ~14 lowerings
each).

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

## 11.5 E9 — Ctor devirtualization at singleton dispatch sites
## (designed 2026-07-18; implementation-ready)

**Why (Run G's mandate).** The `List.cons`-as-HOF rows are the largest
remaining dispatch family (~15 % / 139 M events): `foldr`/`foldrHelper`
dispatch `fn a acc` where `fn` is the `::` CONSTRUCTOR used as a value.
Ctor members ("c|" keys, LSS_003) have NO `MonoClosure` instance, so every
stamp path declines (`declinedNoInstance`, 532 sites unkeyed). Yet the
runtime value of a ctor reference is trivially interchangeable — no
captures, one identity per global — stronger than the lambda case. NOTE
the hot sites live inside SHARED HOF specs whose param sets are JOINS; they
become singletons only under E5 keying of the foldr chain — E9 composes
with E5, and Run H must include a keyed leg to see the weight.

**Mechanism: translate-time callee rewrite (NOT AbiCloning).** The
load-bearing constraint: a devirtualized site needs the ctor's spec AT THE
SITE'S LAYOUT (`::` is polymorphic; one "c|" member covers all layouts),
and only the SOLVER can enqueue specs — AbiCloning is post-mono. Also
verified: `translateCall` has NO VarEnum/VarBox arm — a direct source-level
ctor call already flows through `translateIndirectCall`, whose
`MonoVarGlobal ctorSpec` callee is classified direct by
`annotateCallStaging` and emitted as `eco.call @Ctor_spec` (the Run-D text
MLIR shows `Maybe_Just_$_486` etc.). So the ENTIRE devirt is: rewrite the
indirect call's CALLEE to the ctor reference; every downstream layer
(staging, callInfo, codegen) already does the right thing. The dispatch is
REMOVED, not converted (`sat` drops with no `fast` gain in the census).

**Steps.**

1. **Reverse ctor-member map** (`Engine.elm`): add
   `lssCtorMembers : CoreDict.Dict Int TOpt.Global` to `S`, populated
   wherever a `"c|"` member is minted (the `memberIdFor` call sites that
   hold the actual `TOpt.Global` — LssInfer's VarEnum/VarBox
   `standaloneMember` arms and any Translate twin; thread the global to the
   mint or insert beside it). Lookup helper `Engine.ctorMemberGlobal :
   Int -> Step (Maybe TOpt.Global)`.
2. **Devirt branch** (`Translate.translateIndirectCallBody`): AFTER the
   existing `translate func` (state effects preserved — byte-stability),
   when ALL of:
   - `s.env.lss.enabled`;
   - the callee EXPR is a plain var (`TOpt.VarLocal`/`TrackedVarLocal`) —
     purity guard: rewriting the callee DROPS its computation, and only a
     var read is guaranteed effect-and-⊥-free;
   - `Mono.headAnno (Mono.typeOf monoFunc) == Mono.LSet [ m ]`;
   - `ctorMemberGlobal m == Just g`;
   - `argCount == ctorArity g` (arrow-spine length of g's annotation via
     `lookupAnnotation` — exact saturation only; partial ctor application
     is a PAP, out of scope),
   then translate the callee AS the ctor reference at the site's own
   canonical type — `translateVarRef region g (TOpt.typeOf func)` (this
   enqueues the ctor spec at the site's layout) — and build
   `MonoCall region ctorRef monoArgs resultMonoType defaultCallInfo`;
   otherwise the existing indirect construction, unchanged.
3. **Census**: `ctorDevirt : Int` in `Engine.lssStats` + the
   `renderLssReport` mono census line.
4. **Invariant LSS_015**: singleton-ctor devirt — conditions above; the
   member's interchangeability is definitional (ctors are captureless and
   unique per global); provisional-singleton soundness rides LSS_010 (a
   later join marks the spec dirty and the drain-end flush re-translates
   with the fully-joined demand, re-deciding the devirt).
5. **Pins**: unit `E9CtorDevirtTest` — a ctor passed to a keyed
   recursion-guarded HOF; assert the dispatch site's callee became
   `MonoVarGlobal` (a direct call), RED with the branch neutralized. E2E
   runtime `test/elm/src/CtorDevirtTest.elm` (result CHECK, engine-neutral).
6. **Gates**: elm-tests baseline; solver+LSS self-compile; flag-off
   byte-identity + flag-on corpus (Run-H legs).
7. **Run H**: e2v2 vs e9 binaries; unkeyed census (`ctorDevirt` ≈ the 532
   noInstance singletons' subset) + KEYED-foldr-chain leg (the hot rows);
   dynamic A/B — expect `sat` to DROP on the cons rows (events removed).

Effort: S–M. Risk: LOW-MEDIUM — the rewrite reuses the existing direct-call
pipeline wholesale; the purity guard confines dropped computation to var
reads; LSS_010 covers provisional sets.

### E9.1 — fn-global devirt + the inliner freshening seam (planned 2026-07-18,
### implementation-ready)

**Why (the user's call, and it's right):** an inlined direct function costs
ZERO per call; a devirtualized kernel call still pays the call. The
fn-global devirt's value is precisely the inlining it unlocks — call sites
that were indirect their whole lives become direct calls to small bodies
(`identity`, combinators) the inliner then erases. That door is also the
hazard: the new inline shapes trip a pre-existing codegen/inliner seam
(`lookupVar: unbound variable mono_inline_N` at MLIR emit — the
`Expr.elm:2781` comment documents the crash class: a walker consumes a
let-chain without compiling the inliner-minted bindings, and
`generateLet`'s scope restore leaves them unbound). E9.1 = fix the seam,
then enable the devirt class.

**Step 1 — feature flag (buildable compiler throughout):**
`LssConfig.devirtFnGlobals : Bool` (default False), env
`ECO_MONO_LSS_DEVIRT_FN=1|true|yes`, hash token `lssDF=1` when set (mono
output changes ⇒ must key the artifact cache). Consumed in
`devirtDirectTarget`: the node-kind guard becomes
`isCtorNode g s || (s.env.lss.devirtFnGlobals && isBodyNode g s)` where
`isBodyNode` = Define/TrackedDefine/Cycle (Link-chased). Same var-callee
purity guard, same exact-annotation-arity guard (a multi-stage fn global's
over-arity spine is fine — staging handles it — but v1 keeps EXACT).

**Step 2 — reproduce + localize:** (a) flag-on solver self-compile →
expect `lookupVar: unbound mono_inline_N`; (b) add the CURRENT FUNCTION to
`Context.lookupVar`'s crash (thread `currentFuncName` into `Ctx.Context`,
set where each func's generation starts — codegen-only state, no output
impact); (c) read the named function's mono/inlined form, identify the
shape; (d) minimize into `test/elm/src/FnDevirtInlineTest.elm` — must
CRASH the flag-on E2E harness pre-fix (the RED pin) and print a CHECK
result post-fix.

**Step 3 — fix-space (root-cause among, in likelihood order):**
1. a SEVENTH un-freshened inline seam in `MonoInlineSimplify` (six were
   fixed before; the devirt creates inlinable calls at sites the freshening
   audit never saw — e.g. inlining INSIDE a context the auditor assumed
   couldn't hold a direct call);
2. a codegen walker consuming a let-chain without
   `compileSkippedBindings`-style handling (the BytesFusion precedent —
   check every walker that pattern-matches through `MonoLet`);
3. `generateLet` scope-restore vs. a consumer that emits references after
   the group closes (an ops-ordering rather than scoping bug).
Fix at the source, not by suppressing the inlining (that would forfeit the
value). Add the pin regardless of which suspect it is.

**Step 4 — gates:** repro test green flag-on; flag-OFF byte-identity
(subst AND unkeyed solver legs — the flag defaults off, so shipped
behavior is unchanged); elm-tests baseline; **flag-ON solver self-compile
green — the decisive gate**; flag-on corpus run. Benchmark note: the
dynamic payoff (Run I) rides E1.3-style measurement and is NOT part of
E9.1's goal (planned/implemented/tested); record the census counter delta
only.

**AS BUILT (2026-07-18) — SHIPPED (ctor-scoped) + THREE pre-existing
infrastructure bugs fixed; Run H: −3.49 M dispatch events/run.** The devirt
needed the arg-side standalone-member injection (`standaloneArgMember` —
VarGlobal/VarEnum/VarBox args now contribute members like lambda literals
do; the design's "existing transport suffices" assumption was WRONG for the
fixture class). That injection's first-ever demand-side member churn exposed
and forced fixes for: (1) dirty-flush re-translation of shape-derived specs
(value-typed registry entries → ctor-scheme unify crash) — now skipped via
`nodeSupportsRetranslation`; (2) `updateRegistryType` overwrite discarding
demand-side annos — join-grow/update-shrink PING-PONG, flush never
converged; the update now JOINS (flag-off keeps the plain update); (3)
`Engine.S` hit the native 32-slot record scan cap at 33 fields (the
compiler SELF-HOSTS — its own state records must respect runtime limits!);
member tables merged into one `lssMemberTable` sub-record. SCOPE
CORRECTION: devirt restricted to actual `Ctor`/`Box` nodes — devirtualizing
FUNCTION globals feeds the inliner new direct-call shapes that trip a
pre-existing freshening seam (`lookupVar: unbound mono_inline_N` at MLIR
emit; reproduced, documented) — E9.1 follow-up gated on hardening it.
KEY GAP FOUND: `List.::` is NOT an ordinary Ctor node (kernel-represented)
— THE cons class (15 % of dispatch, this section's original motivation) is
NOT yet captured; E9.2 = give cons a devirt-able representation. Run H:
`devirtDirect=2454` unkeyed (output −80 KB), dynamic sat −3,487,524
(events REMOVED; fast unchanged — the devirt signature), coverage
5.39→5.41 %. COST: solver mono wall +38 % same-run (10:04→13:56) from the
injection's re-translation rounds — E9.3 = cap/registry-join optimization
before enabling more injection classes. All gates green (12998/12, corpus
1623/1623 incl. CtorDevirtTest, subst byte-identical). Debug playbook
addition: the enqueue-trap + deep errDeep rendering + currentGlobal/
flush-round context in unify failures are now PERMANENT diagnostics.

**E9.1 AS BUILT (2026-07-18) — SHIPPED flag-gated (`lss.devirtFnGlobals` /
`ECO_MONO_LSS_DEVIRT_FN` / hash `lssDF=1`, default OFF); Run I: −53.1 M
dispatch events/run, the largest reduction of the track.** Devirt guard
extended to body-bearing globals via `isBodyNode` (Define/TrackedDefine/
Cycle, Link-chased). The blocking crash was NOT an inliner freshening bug:
BytesFusion's reifier walks past `MonoLet` bindings via `exprCache`, so
residual `MonoExpr`s inside Encoder/DecoderNodes referenced `mono_inline_N`
bindings never compiled at the emit callback (`lookupVar: unbound`, at
self-compile scale in `Mlir.Bytecode.StreamEncode.assembleModule`). Fix at
the fused-emit boundary: `Expr.bfExprCompiler`/`resolveFusedLets` substitute
walked-past bindings ONLY when absent from `ctx.varMappings` (working paths
untouched); site-local `collectFusedLets` + miss-path
`findLetInInlineBodies` (bindings inside inlined spec bodies are invisible
to site-local collection — the second half of the bug). PERMANENT
diagnostics added: `Context.currentFuncName` (+ `/bf-enc` tag) and in-scope
mono_inline list in the lookupVar crash. The E2E fixture
(`FnDevirtInlineTest`) pins devirt+inline+fusion functionally but does NOT
reproduce the seam — the self-compile is the RED/GREEN repro (neutralize →
Stage 5 crashes; restore → green, both demonstrated). Test hardening:
`FusionPartialOpaqueTest` needed a runtime 2-member `pickEnc` (fn devirt
resolved its "opaque" param and the whole encoder fused — a strictly
better compile over-failing an over-specified CHECK). Gates: flag-off
solver AND subst byte-identical e9↔e91 (seam fix provably inert), DF-on
self-compile green, DF corpus 1624/1624, elm-tests 12998/12. Run I:
`devirtDirect` 2,455→6,458 (+4,003; noInstance −3,023 + ~980 second-order),
output +202 KB (+1.67 % — inlined bodies), sat −52.94 M / events −53.1 M
(−5.65 %), fast −0.16 M (fast sites upgraded to direct), coverage
5.41→5.72 %. COST: flag-on mono wall +46 % (13:04→19:02, E9.3 now BLOCKING
for default-on) and an UNRESOLVED instrumented workload-wall read
(4:57→6:42, single run, noisy machine — uninstrumented multi-run A/B
required before any default-on decision).

### E9.2 — kernel devirtualization (E9-K), whitelist = `List.cons`
### (planned 2026-07-18, implementation-ready)

**Why.** The cons rows are the largest dispatch family (139 M/run = 15 % of
Run A; STILL uncaptured after E9/E9.1 — Run H's keyed leg moved devirt by
+1). `List.::`/`(::)`/`List.cons` is kernel-represented end to end: source
`cons = Elm.Kernel.List.cons`, cons-as-value is `TOpt.VarKernel "List"
"cons"`, and the runtime kernel is a pure allocator
(`ListExports.cpp: Elm_Kernel_List_cons` + typed `cons_Int/Float/Char`
variants with unboxed heads). The intrinsic-grade DIRECT form already
exists: a written-out `x :: xs` compiles via `translateKernelCall` →
`deriveKernelAbiTypeCall` picks the typed variant per element layout →
direct kernel call, no dispatch. E9.2 rewrites a singleton-`{k|List.cons}`
indirect call into exactly that form. No Elm shim (the shim's inlined body
IS this same kernel call — identical endpoint, more moving parts, plus an
`lssDF` dependency), no ctor node for List, no new MLIR ops. Beyond-
direct-call speed (inline nursery allocation — today even literal
`eco.construct.list` lowers to `call eco_alloc_cons`,
`EcoToLLVMHeap.cpp:349`) is a SEPARATE backend item (E9.4), orthogonal to
this rewrite and compounding with it.

**Verified ground truth (2026-07-18, code-read):**
- LssInfer ALREADY mints + injects the kernel member at every occurrence,
  arg positions included: `walkExpr`'s `VarKernel` arm (LssInfer.elm:638)
  → `standaloneMember ("k|" ++ home ++ "." ++ name)` → head-only
  `injectSpineMemberId 1`. The report's "piece 2" (arg-side VarKernel
  injection) therefore ALREADY EXISTS; transport to HOF param slots rides
  the same call unification as ctor members. What is missing is only
  (a) the member→kernel reverse map and (b) the devirt arm + rewrite.
- LSS_004 kernel poison is about calls TO kernels (arrows crossing the
  kernel ABI); it does not touch the kernel VALUE's own identity member,
  and `cons : a -> List a -> List a` has no arrow args anyway.
- `translateIndirectCallBody` translates ARGS FIRST, then the callee, then
  decides devirt — so the kernel arm must NOT call `translateKernelCall`
  wholesale (it re-translates args = doubled state effects). It must build
  the call from the already-translated `monoArgs`, deriving the kernel ABI
  post-hoc (see step 3). The direct path's derive-BEFORE-args ordering
  exists for number-demand concretization of literal args; at devirt sites
  the args were already unified against the callee var's arrow (fully
  concrete in a spec body), so post-hoc derivation is a no-op refinement.
  Caveat recorded: if a whitelisted kernel with number-polymorphic literal
  args ever devirts, re-examine this ordering. For cons it is moot.

**Step 1 — Engine: kernel reverse map (NO new `S` field — 32-slot cap).**
`LssMemberTable` gains `kernels : Dict Int ( Name, Name, Name )`
(prefix, home, name — prefix needed to reconstruct `MonoVarKernel`
exactly). New `kernelMemberIdFor : String -> ( Name, Name, Name ) -> Step
Int` mirroring `standaloneMemberIdFor` (same interning, idempotent reverse
insert) and `standaloneMemberKernel : Int -> Step (Maybe ( Name, Name,
Name ))` mirroring `standaloneMemberGlobal`. `emptyMemberTable` gains
`kernels = empty`.

**Step 2 — LssInfer: register the kernel identity at the mint.** The
`walkExpr` `VarKernel` arm binds `kernelPrefix` (currently `_`) and mints
via `standaloneMemberWith (Engine.kernelMemberIdFor ("k|" ++ home ++ "."
++ name) ( kernelPrefix, home, name )) meta` — the "k|" KEY is unchanged
(same member ids as today; only the reverse map is new). Accessor arm
stays plain.

**Step 3 — Translate: the devirt arm.** `devirtDirectTarget` returns
`Maybe DevirtTarget` where `type DevirtTarget = DevirtGlobal TOpt.Global |
DevirtKernel Name Name Name`. Decision, after the existing singleton +
plain-var-callee guards: if `standaloneMemberGlobal` misses, consult
`standaloneMemberKernel`; require the WHITELIST — v1 exactly
`( home, name ) == ( "List", "cons" )`, which also pins arity — and
`List.length args == 2` (exact saturation; a partial is a PAP, out of
scope). Whitelist rationale: kernels can be effectful and have no
annotation to arity-check against; the list is the soundness boundary and
each addition must argue purity + arity. In `translateIndirectCallBody`'s
`DevirtKernel` arm, build the direct form on the ALREADY-translated args:
`deriveKernelAbiTypeCall ( home, name ) (TOpt.typeOf func) args` →
`funcMonoType` (typed-variant selection: `cons_Int` in an Int spec —
unboxed head, a bonus the generic evaluator path can never have) →
`callResultType (List.length args) funcMonoType callCanType` →
`Mono.MonoCall region (Mono.MonoVarKernel region prefix home name
funcMonoType) monoArgs resultMonoType Mono.defaultCallInfo` — byte-wise
the same call form a written-out `x :: xs` produces. (`indirectResultAnno`
not needed: cons's result `List a` carries no arrows, and the kernel path's
`callResultType` is what the direct form uses.) The ctor/fn arms are
untouched (`DevirtGlobal` preserves today's behavior exactly).
Provisional-singleton soundness rides LSS_010 unchanged: a later widen
re-translates the node and the devirt re-decides.

**Step 4 — census.** `LssStats` gains `devirtKernel : Int` (separate from
`devirtDirect` for attribution); bump in the `DevirtKernel` arm; print in
`Monomorphize.elm`'s report line next to `devirtDirect`.

**Step 5 — invariant.** LSS_016: a singleton `{k|home.name}` at an exactly
saturating plain-var call site may be rewritten to the direct kernel call
IFF (home,name) is on the kernel-devirt whitelist (v1: List.cons only);
whitelist entries must be pure (no effects, no bottoms beyond the value's
own semantics) and their arity pinned by the whitelist. Add to
`design_docs/invariants.csv`.

**Non-flag decision.** Like E9 (ctors) and unlike E9.1 (fn globals), E9.2
ships UNCONDITIONAL under `lss.enabled`: the rewrite lands on the
battle-tested kernel-call form, no inliner surface is added (kernel calls
are never inlined), and the whitelist bounds exposure to one pure
allocator. No config/hash change. Cost watch: the kernel member class adds
no NEW injection (the mints predate E9.2); only devirt-triggered
re-translation churn is new — measure the mono wall in Run J and file
under E9.3 if it moves.

**Step 6 — pins + gates (order).**
1. `test/elm/src/ConsDevirtTest.elm` — mirror `CtorDevirtTest`'s shape: a
   LOCAL non-tail fold (single provenance → singleton without keying) with
   `(::)` passed as the HOF value, plus an Int-element leg so the typed
   `cons_Int` variant is observable; `-- CHECK:` the folded result. RED
   first (assert the direct-call MLIR shape via CHECK-MLIR on
   `Elm_Kernel_List_cons`/kernel-call form — absent pre-implementation),
   GREEN after. Corpus gotcha: touch all test `.elm` before flag-on runs
   (env-blind mtime cache).
2. elm-tests baseline (12998/12) — kernel devirt is solver/LSS-gated, the
   JS/subst front-end must be untouched.
3. Subst byte-identity A/B on the compiler tree (flag-off legs).
4. **Native solver+LSS self-compile — THE gate** (S.10/S.11 doctrine).
   Watch specifically for: devirt firing inside `Bytes`-fusion contexts
   (the kernel call is a plain MonoCall — BytesFusion treats it as any
   saturated kernel call, but this is the first devirt class that lands
   INSIDE fused encoder subtrees at scale) and the `declinedShape` /
   census accounting still closing.
5. Flag-on corpus (touch-all), expect 1625/1625 with the new pin.

**Step 7 — benchmark = Run J (two-phase clean method, this doc's
Methodology).** Legs: `e91-solver` (baseline binary, unkeyed) /
`e92-solver` (unkeyed) / `e92-solver-keyed` (the Run-F List chain
`elm/core:List.foldl,List.foldr,List.foldrHelper,List.map` — the hot cons
dispatches live in SHARED fold specs, so the keyed leg is where the 139 M
class converts; unkeyed converts only single-provenance sites) /
`e91-subst` / `e92-subst` (byte-identity). Dynamic census A/B: lower
e91-solver, e92-solver, AND e92-solver-keyed with
`ECO_LSS_DISPATCH_SITE_COUNTERS=1`; cold `ECO_DISPATCH_STATS=1`
self-compile each; the E9-family signal is EVENTS REMOVED
(sat+fast delta), not coverage. Record devirtKernel, mono walls (E9.3
watch), output sizes. `lssDF` stays OFF for all legs (default config —
E9.2 must be measured on shipped-config behavior).

Effort: S. Risk: LOW — smaller surface than E9 (one whitelisted kernel,
existing call form, no new injection); the named risks are the
BytesFusion-context interaction and re-translation churn, both measured at
the gates.

**IMPLEMENTATION CORRECTIONS (2026-07-18, found via the unit pin's RED):**
1. **Operator-as-value is a GLOBAL, not a VarKernel.** `(::)` canonicalizes
   via `Names.registerGlobal` (LocalOpt Typed Expression's `VarOperator`
   arm) to `VarGlobal (elm/core List) cons` — the "verified ground truth"
   claim that cons-as-value is `TOpt.VarKernel` was WRONG (VarKernel occurs
   at direct call sites via the Binop arm, and inside the alias's own def
   body). So the devirt-relevant member at HOF-arg sites minted as
   `g|List.cons`, whose node is not a Ctor → E9 declined it.
2. **The mint that matters is Translate-side, not LssInfer-side.** E9's
   arg-side standalone injection lives in `Translate.injectArgLambdaMember`
   (:2749) — that is what writes members into the solver store the devirt
   reads. The LssInfer `walkExpr` arms feed signatures only.
3. **The fix is an IDENTITY FOLD, not a second resolve path**: at BOTH
   mint sites (Translate's `injectArgLambdaMember` VarGlobal arm and
   LssInfer's `walkExpr` VarGlobal arm), a kernel-ALIAS global — node is
   `Define`/`TrackedDefine` whose body is EXACTLY a `VarKernel`
   (`cons = Elm.Kernel.List.cons`), Link-chased (`LssInfer.kernelAliasOf`)
   — mints the KERNEL member `k|home.name` (via `kernelMemberIdFor`, which
   registers the (prefix,home,name) reverse map) instead of `g|`. One value
   = one identity: a split g|/k| identity would join to a 2-set and kill
   every singleton consumer. The `k|` devirt leg then handles everything;
   no `kernelAliasOf` consult in the devirt decision itself.
   Consequence flag-on-DF: kernel-alias globals no longer devirt via the
   E9.1 fn-global path (they are k| now, whitelist-gated) — a Run-I-vs-J
   census shift under `lssDF=1` only; default config unaffected.
4. **Unit-env fidelity**: TestPipeline's mock env carries dependency
   ANNOTATIONS but no nodes (node-less globals become `MonoExtern`), so
   `kernelAliasNodes` synthesizes the production-true `List.cons` node
   (`Define (VarKernel "Elm" "List" "cons")`) for the pin. Unit pin:
   `E92ConsDevirtTest` (RED/GREEN proven; asserts no VarLocal-callee call
   remains AND a `MonoVarKernel List cons` call EXISTS, with callee-anno +
   node-key diagnostics in the failure message).

**TIER-1 HARDENING (2026-07-20) — the CNumber-residual soundness hole,
found by the first keyed×DF corpus and fixed with three guards.** Three
Combinator fixtures crashed at MLIR emit: `Kernel signature mismatch for
Elm_Kernel_List_cons_Int: (i64, eco.value → eco.value) vs (i64, i64 → i64)
[in List_foldl_$_N]` (the `[in …]` provenance is a new permanent CGEN_038
diagnostic). ROOT CAUSE (probe-verified — the devirt-emit probe showed the
site typed `(MVar CNumber, MList (MVar CNumber)) → MList (MVar CNumber)`):
the kernel devirt fired at a translation whose types still carried
RESIDUAL NUMBER VARS; the demand-close is a POSITIONAL TYPE-ANNOTATION
REWRITE, not a re-translation — it stamps the settled demand onto node
types but cannot re-derive kernel ABIs or un-devirt, an invariant that is
sound for the layout-AGNOSTIC nodes the normal translator produces
(indirect calls, boxed convention) and was broken by the layout-COMMITTED
direct kernel call. Cons flows into `List.foldl` legitimately
(`reverse = foldl cons []`; `foldrHelper` forwards its own `fn` into
`foldl fn acc (reverse r4)`); at an unsettled site the close later
collapsed the number positions (to Int here; a Float program would poison
identically) leaving the frozen cons call ill-typed. FIXES (all decline ⇒
`indirectCallFallback`, always correct): (1) shape guard on the derived
callee type (curried AND flat spines — the unit pin caught a flat-only
version silently declining EVERYWHERE, devirtKernel=0: the corpus cannot
distinguish devirt from fallback, ONLY the pin can); (2) emission guard on
the ACTUAL monoArgs/result types (codegen derives the kernel DECL from
those, and preserved-vars callee types pass the shape guard while args are
scalar); (3) **deep CNumber-freedom** over head/tail/result
(`containsCNumber` — the decisive one; the residue hid INSIDE `MList`).
Plus: kernel-ALIAS globals now route through the kernel whitelist in
`devirtDirectTarget` (never the E9.1 fn-global path — DevirtGlobal +
inliner would plant the raw kernel call at the site type; defense in
depth even though the observed producer was the kernel arm itself).
Debugging trail for the record: THREE wrong producer theories
(instanceClosureResult value path, translateKernelCall, ecoCallNamed)
were eliminated by probes before the devirt-emit probe told the truth —
`registerKernelInstance` fires BEFORE `ecoCallNamed` in the direct-call
emission, which is why the ecoCallNamed probe only saw the healthy
registration. Guards cost ZERO devirts at self-compile scale
(devirtKernel=784 unchanged, Run L). OPEN (E9.5): why the winning demand
for that spec closed b to Int when the translation-time shape was
list-flavored — the layout-blind demand-join question; the guards make it
unexploitable meanwhile. V2 DESIGN NOTE (ordering insight, user-prompted):
the guard is the conservative approximation of the RIGHT architecture —
commit-after-settle. A post-close revisit would legitimately devirt the
late-settling cons-shaped sites (settle → cons-shaped → typed variant;
settle → non-cons-shaped → stay indirect). The clean implementation is to
MOVE the kernel devirt out of translate-time into GlobalOpt/AbiCloning,
which already runs on fully settled types and consumes the same singleton
annos: the kernel rewrite (unlike the ctor one) needs NO translate-time
machinery — it only swaps a MonoVarLocal callee for a MonoVarKernel. No
ordering hazard, no guards, late sites captured. Do this with E9.5 if a
census ever shows late-settling cons sites carrying weight (today: zero
at self-compile scale).

**AS BUILT (2026-07-19) — SHIPPED unconditional under lss.enabled; Run J:
−159.9 M events/run keyed (−16.9 %), THE cons class captured.** All gates
green: unit pin RED/GREEN; elm-tests 12,999/12 (baseline + new pin);
default corpus 1624+1 (the one first-pass failure was the fixture's own
CHECK — `Debug.log` prints Strings QUOTED, `result2: "ab"`); flag-on
corpus 1625/1625; flag-on native self-compile green FIRST TRY with
`devirtKernel=763` live (devirtDirect 2,455 unchanged — the identity fold
does not disturb ctor devirt); subst legs byte-identical. Static: keyed
+21 devirts only (784) but those sites carry ~143.7 M dynamic events —
few-sites × huge-weight, exactly the Run-A concentration; unkeyed −16.2 M
(763 single-provenance sites, 4.6× E9's ctor haul); output −795 B unkeyed
(direct kernel calls SMALLER than dispatch), +13.4 KB keyed; mono walls in
noise (no E9.3-scale cost added); census walls flat across legs (no
Run-I-style workload-wall signal). All removal came out of `gen` (typed
identical) — cons dispatch was pure generic-funnel. FOLLOW-UPS opened:
List-chain keying default-on decision (E5's payoff went 0 → 143.7 M with
E9.2 — measure the keyed mono wall on a quiet machine, then decide);
census-driven whitelist growth; E9.4 inline nursery allocation
(every cons is still a runtime call at machine level). Run J recorded in
benchmarks/runtime-calls.md.

### E9.3 — flag-on mono-wall cost: measured attribution + allocation-free
### set joins (planned 2026-07-19, implementation-ready)

**Problem restatement (evidence-corrected).** The E9-family "mono wall
+38 %/+46 %" turns out to be THREE conflated effects, separated on
2026-07-19 by gdb-sampled profiles (poor-man's profiler, ~400 samples/run,
job-tmp `prof/`, analyzer `pmp-analyze.py` + `pmp-diff.py`):
1. **Leg-position/page-cache penalty in the benchmark methodology** —
   reproducible in our own data: Run I's e9 (first leg, cold) 15:42 vs e91
   (second leg) 13:03 on BYTE-IDENTICAL work; Run J's first leg 16:26 vs
   13:49/13:44. First legs pay ~+20 %. NOT machine drift — a within-run
   artifact. Run K fixes the protocol (warm-up leg, below).
2. **The real e2v2→e92 regression, measured controlled** (same day, same
   position, same sampling overhead): 844 s → 960 s = **+116 s (+13.7 %)**.
   Bucket diff: RUNTIME_GC **+52.8 s** + runtime-other +26 s (two-thirds
   is ALLOCATION CHURN); Type_Unify +19.2 s (3.6×), MonoSolver_Store
   +16 s, AST_TypedOptimized +13.9 s (mint-key string builds),
   AST_Monomorphized +12 s (anno joins). Controls flat
   (Analysis/AssignMVarIds/UnionFind ±0.2 s; collectCustomTypes is
   anno-blind and did NOT grow). No new hot function — the regression is
   the SAME operations made heavier by E9's +29 % concrete-set population
   (singleton arrows 66,138 → 86,132; census diff bench-e9/census-e2v2-*
   vs census-e9-*).
3. **Falsified attributions (do not re-chase):** flush volume
   (retranslations 882 → 1,146 = ≤ ~1 min); E9-specific frames
   (inject/mint/devirt/registry ≈ 1 % of samples); DF's "+46 %" (Run I's
   19:02 was a first-leg read; controlled P1 vs P2 = 16:00 vs 16:14);
   layout-key length (keys are anno-blind).

**Root mechanism (code-verified).** `Store.unifySlotWithSet`
(Store.elm:751) services EVERY set write — member injection (args, spine,
facts) and every LSS_004 kernel poison — by ALWAYS allocating a fresh UF
Point + descriptor + `Dict.fromList` set structure (`Engine.freshVar`) and
running a full `unifyStep`, even when the join is a NO-OP. With ~90 % of
slots ⊤ and injection member lists of size 1, the overwhelming majority of
these millions of executions allocate garbage to compute nothing. The
Unify `LambdaSet1×LambdaSet1` arm (Unify.elm:751) likewise allocates
`Dict.union members1 members2` on every slot×slot unification even when
one side subsumes the other. Join semantics: `(top1 || top2, union)` —
total, monotone.

**Design (v1, two edits, both pure perf — the fixed point is unchanged):**
- **(A) Read-first no-op skip in `unifySlotWithSet`:** `UF.get slot`; if
  the content is `LambdaSet1 slotTop slotMembers` and
  `(slotTop || not top) && List.all (\m -> Dict.member m slotMembers) members`,
  the join result IS the current content — return with no fresh var, no
  Dict build, no unify. Otherwise fall through to the existing path
  unchanged. (Poison of an already-⊤ slot and re-injection of a present
  member — the dominant cases — both hit the skip.)
- **(B) Subset-reuse merge in Unify's `LambdaSet1` arm:** if
  `(top2 ⇒ top1) && members2 ⊆ members1`, merge with the FIRST content
  as-is (no union allocation); symmetric other side; only build
  `Dict.union` when neither subsumes. Sets are ≤ 8 members (widening
  cap), so the subset test is trivially cheap.

**Soundness/observability + the one risk.** In every skip case the
resulting store CONTENT is bit-equal to what the full path produces; all
engine vars share `outermostRank`, so rank bookkeeping is degenerate. The
only machine-state difference is the elided fresh var: the store's
var-count advances differently, so LATER points get different indices.
Nothing output-affecting is supposed to key on raw point numbers
(`pointKey` feeds seen-sets/diagnostics; specs key on layout strings;
members have their own id supply) — but the byte-gate decides, not the
argument: **flag-on solver self-compile MLIR must be byte-identical to
e92's `out-e92-solver.mlir` on the same tree** (no compiler-src change
since e92 except E9.3 itself). If byte-identity FAILS, diagnose the leak;
do not ship on "runtime-equivalent" without understanding it.

**Gates (order):** (1) elm-tests baseline 12,999/12; (2) subst
byte-identity; (3) **flag-on native self-compile green AND byte-identical
to e92's flag-on output**; (4) flag-on corpus 1625/1625 (touch-all);
(5) census equality vs e92: identical `lss globalopt` +
devirtDirect/devirtKernel + flush lines (same decisions, only faster).

**Run K (benchmark, corrected protocol).** Two-phase clean method PLUS:
leg 0 = un-timed WARM-UP (discarded) so no timed leg pays the
first-position penalty; then INTERLEAVED timed legs e92/e93/e92/e93
(flag-on unkeyed, `rm -rf eco-stuff` each), one e93-keyed leg, subst
byte-identity legs. NO gdb sampling in timed legs. Optional: an e93 DF leg
to restate Run I's walls under the corrected protocol. Report: wall delta
(expect roughly −60 s on the ~13:50 flag-on wall — the skip also wins on
the PRE-E9 baseline population, kernel poisons included), and the
census-equality verdict. Record as Run K in benchmarks/runtime-calls.md
and RETIRE the "+38 %/+46 %" attributions.

**Non-goals (v2 candidates, census-driven):** mint-key string-build
reduction (AST_TypedOptimized +13.9 s — needs an id-order-preserving memo;
not worth output instability in v1); collectCustomTypes miss-path double
stringification (pre-existing, not a regression); signature/Solve growth
(+4.6 s each); retranslation-count reduction (bounded ~1 min; LSS_010's
correctness story stays simplest as-is).

**AS BUILT (2026-07-20) — v1+v1.1 SHIPPED (wall-neutral, byte-proven) +
THE REAL FINDING: major-GC trigger policy is 56 % of the flag-on wall;
one config line = −53 %.** Chronology and evidence (Run K,
benchmarks/runtime-calls.md):
1. v1 (no-op skip + Unify subset-reuse) measured ZERO wall win — root
   cause: LSS_006 means set writes target FRESHLY-MINTED flex slots, so
   the "already constrained" fast path never fires. v1.1 added the
   flex-slot direct-set (`UF.set` content adoption — what unify(flex ×
   LambdaSet1) merges to, minus the fresh var + unifyStep). Also
   wall-neutral (±10 s interleaved; −2 s under the low-GC regime). KEPT:
   provably inert (byte-gate ×4 legs + subst + census + 12,999/12 +
   1625/1625), allocation-avoiding, and the byte-gates pinned a
   load-bearing fact: elided fresh vars do NOT leak through point
   numbering.
2. The wall itself decomposed via GC stats: **major GC = 470 s of the
   834 s flag-on wall (103 majors × 4.56 s)**. Major counts are
   deterministic per (binary × tree) — exactly reproduced across Run-K
   legs — but chaotically input-sensitive across trees/binaries (same
   binary: 94 vs 135 majors = 13:03 vs 16:26). This retro-explains the
   "+38 %/+46 %" as GC-trigger lottery (e2v2: 62 majors vs e9: 108; DF
   controlled = +14 s) and retires the "first-leg/page-cache" reading
   (majflt=0 everywhere; the user's no-drift claim was correct).
3. Trigger breakdown: 95/103 majors = **GlobalPressure**
   (`committed ≥ occupancy/3 ≈ 28.3 % of old-gen cap`,
   OldGenSpace.cpp:evaluateMajorGCTrigger; stale in-code comment still
   says 0.25/0.75) — the cap is HALF the `max_heap_size` VIRTUAL
   reservation (`nursery_offset = heap_reserved/2`, Allocator.cpp:214),
   so the bar ≈ 14.2 % of the reservation = ~3.4 GB committed with the
   24 GB default, on a ~2 GB-live workload; 96g moves it to ~13.6 GB.
   `ECO_HEAP_CONFIG='{"max_heap_size":"96g"}'`: majors 103 → 12,
   **wall 13:44 → 6:27 (−53 %), RSS +1.7 %, output byte-identical**.
   Anti-lesson: `initial_old_gen_size=6g` is PESSIMAL (committed/cap
   starts over the bar → major per minor, 1227/1227, 1:03:53).
4. Standing methodology: walls are meaningless without `Major GC cycles`
   + trigger counts; pin ECO_HEAP_CONFIG for wall A/Bs; warm-up leg +
   interleave. The controlled e2v2→e92 compute regression is +116 s
   (+13.7 %): two-thirds GC/alloc churn from the +29 % concrete-set
   population, the rest smeared set machinery — the INHERENT cost of
   carrying lambda-sets, now bounded and understood.
FOLLOW-UPS: (a) ~~GlobalPressure `/3` policy revisit~~ **DONE (user
decision, 2026-07-20): new HeapConfig field
`major_gc_global_pressure_fraction`, DEFAULT 0.85** (decoupled from
`initiating_occupancy` — the /3 coupling was accidental and its comment
stale; both OldGenSpace sites updated; JSON-configurable). Verified: stock
run = 12 majors / GlobalPressure 0 / wall 6:35 / RSS +1.8 % /
byte-identical; check 1625/1625. Small-cap embedding measurement remains
open; (b) lssDF default-on UNBLOCKED from the compile-time side;
remaining blocker = Run I's instrumented workload-wall read; (c) v2
micro-candidates above remain unclaimed.

## 11.6 E10 — post-settle kernel devirt: relocate to GlobalOpt
## (design-first exploration, added 2026-07-20)

**Origin.** The Tier-1 hardening proved translate-time kernel devirt is
COMMIT-BEFORE-SETTLE: it freezes a layout-committed kernel identity while
the site may still carry residual `CNumber` vars, and the demand-close (a
positional annotation rewrite that cannot re-derive kernel ABIs or
un-devirt) then collapses those positions out from under it. The three
E9.2 guards enforce "commit only what is already settled" — sound, but
the conservative approximation. The right architecture (user-identified):
**commit-after-settle** — decide the devirt where types are final, so
late-settling sites are CAPTURED (settle → cons-shaped → typed variant)
or correctly refused (settle → non-cons-shaped → stay indirect) instead
of blanket-declined.

**Design sketch.** A GlobalOpt pass in/adjacent to AbiCloning — which
already runs post-mono on fully settled types and consumes the same
singleton annotations for the fast-dispatch stamps. Walk `MonoCall` sites
with a `MonoVarLocal` callee whose head annotation is a singleton
`{k|home.name}` on the WHITELIST at exact whitelist arity, and swap the
callee for `Mono.MonoVarKernel` at the site's (final) types. Unlike the
ctor devirt, NOTHING from translate-time is needed: no `translateVarRef`,
no spec enqueue, no solver store — emission already derives the kernel
decl/variant from the node's final types, which is exactly what makes the
post-settle position safe. The E9.2 guards and the translate-time
`DevirtKernel` arm are then DELETED — one mechanism, no ordering hazard
by construction.

**Known design points to explore (why this is design-first):**
1. **Member→kernel resolution post-mono:** the `lssMemberTable.kernels`
   reverse map lives in `Engine.S`, which is discarded after mono.
   AbiCloning resolves members via the instances/registry plumbing that
   IS exported — the kernels map must ride the same channel (thread it
   into the GlobalOpt env alongside the member/instance tables).
2. **Node shape parity:** the swapped call must match what
   `translateKernelCall` produces (callInfo, staging attributes) so
   `annotateCallStaging`/emission treat it identically — audit the
   attrs a kernel MonoCall carries and whether GlobalOpt ordering
   (pass runs before/after staging annotation) needs the swap early.
3. **Anno availability:** confirm the `{k|…}` singleton survives on the
   callee var's MonoType annotation at GlobalOpt time for exactly the
   site population the translate-time arm sees today (it should — the
   stamps read the same annos — but verify with a census A/B).
4. **Sizing the prize (E10.0, do FIRST):** add a `declinedUnsettled`
   census counter to the current guards and measure at self-compile +
   corpus + a numeric-heavy fixture. Today's evidence says ~0 at
   self-compile (devirtKernel 784 with and without guards) — if the
   late-settling population stays ~0 everywhere, E10 is hygiene
   (guard/arm deletion, single mechanism) rather than coverage, and can
   wait for whitelist growth to justify it.

**Gates when implemented:** flag-on self-compile MLIR byte-identical to
the translate-time mechanism on settled sites (the swap should emit
identically); the Combinator trio green WITHOUT the guards (the
non-cons-shaped closings must refuse naturally); `E92ConsDevirtTest`
re-targeted at the GlobalOpt pass; census: devirtKernel ≥ today's 784
(strictly more if late-settling sites exist).

**Relationship to E9.5:** same machinery neighborhood (the layout-blind
demand-join audit explains WHY non-cons-shaped closings of cons-claiming
slots exist at all); do E10 with or after E9.5.

## 11.7 E11 — key-on-conflict: whitelist-free selective keying
## (outline only, added 2026-07-20)
## PREREQUISITE LANDED (2026-07-20): Fix B shipped + gated
## (`plans/lss-fork-qualified-members.md`) — all-globals keying is now
## SOUND, and Run M (benchmarks/runtime-calls.md) measured it: coverage
## 6.81%→13.22% at identical total events and wall parity. E11 is
## therefore a COMPILE-COST optimization (fork less than all-globals),
## not a soundness gate: decide it against a post-Fix-B all-keyed
## compile-wall A/B (majors recorded — the fork population grew;
## widenedByBudget=46,394 on the keyed self-compile).

**Motivation.** The Run-L census's actionable tier is un-keyed HOF hosts
(`Maybe.map`, `System.TypeCheck.IO.traverseList`/`IO.map`, the hosts of
`typeHasResidualNumber`/`applySubstPure`/`identity` rows, a residual
6.2 M `List.cons` evaluator). The keying whitelist is a BUDGET device,
not a correctness device — and it cannot name WORKLOAD globals: a
compiler-shipped list may only contain standard-lib entries
(`elm/core:*`, `eco/*`); `System.TypeCheck.IO.traverseList` is the
compiled program's own code. Per-project `eco-config.json` keying exists
but is manual tuning. Key-on-conflict keys hosts automatically, with no
one naming anything.

**Trigger (the core idea).** Fork a spec precisely when a JOIN is about
to destroy usable information. At `enqueueSpec`, when the incoming
demand carries a SINGLETON STANDALONE MEMBER (g|/c|/k| — anything a
stamp, E9/E9.2 devirt, or DF could consume) on some arrow, and the
existing spec's set for that arrow DIFFERS (a different singleton, a
multi-set, or ⊤ — any join result that is not the same singleton), key
the incoming demand into its own spec instead of joining. The trigger IS
the lost singleton, so fan-out occurs only where sets genuinely diverge
AND a consumer could have used the information. Self-targeting:
`traverseList` in the compiler workload, `Maybe.map` in stdlib, and any
user HOF key exactly when it pays.

**Cost bounds.** Fan-out ≤ real set diversity per (global × layout), and
`maxSpecsPerGlobal` already caps the worst case (past budget, new demands
key set-widened — the M4 machinery). Expected far below all-globals
keying: conflict-free globals (the overwhelming majority) never fork.

**Open questions for the detailed design (outline-level only here):**
1. Key identity: reuse M4's keyed-spec key form (layout × set key) so
   downstream (registry, AbiCloning, EngineDiff) is unchanged; the fork
   decision is the ONLY new logic.
2. Exact conflict predicate: singleton-vs-⊤ joins (⊤ absorbs — clearly a
   conflict), singleton-vs-different-singleton (conflict), singleton-vs-
   same-singleton (no conflict — join is a no-op), multi-vs-anything
   (no fork — nothing usable to save). Arrow position scope: params
   only? head-only vs spine?
3. Retroactivity: the conflicting join usually arrives AFTER the shared
   spec exists — fork the NEW demand (leave the old spec); does the OLD
   spec deserve a dirty re-key when its own surviving set becomes
   singleton? Interplay with LSS_010 flush.
4. Relationship to Tier-1 defaults: if E11 ships, `defaultKeyedGlobals`
   is subsumed and retires (it becomes a pre-seeded special case).
5. Census: `keyOnConflictForks` counter + per-global fork histogram —
   needed to verify the self-targeting claim and watch for pathological
   workloads (elm-aws-codegen class).

**Sequencing:** measure ALL-GLOBALS keying under the new baselines FIRST
(one bench — the +28 % verdict is old-GC-policy vintage; if all-globals
is now cheap, E11 is unnecessary). E11 is the fallback design if
all-globals still costs too much.

**ALL-GLOBALS RE-MEASURE DONE (2026-07-20) — cheap but MISCOMPILES; E11
is the live path.** Interleaved bench (`ECO_MONO_LSS=keyed`, tier1
binary, warm-up + ×2 pairs, `bench-allkey/`): compile cost is now only
**+5.7 % wall** (6:08.5/6:09.2 → 6:30.7/6:28.6; 2 of the ~21 s are +2
majors, so compute ≈ +3 %), output +4.4 %, RSS +1 % — the M4-era "+28 %"
verdict is RETIRED (old GC policy). Static value is real:
`dispatchUpgraded` 2,409 → 3,028 (+619), `stampedStaged` +117,
`devirtDirect` +148 (`devirtKernel` 764 vs 784 — −20, un-investigated;
possibly guard declines inside newly-forked specs). Keyed output
deterministic across legs. **BUT the all-keyed binary SIGSEGVs ~7 s into
its first self-compile workload** (census leg rc=139, 1 major GC, core
preserved: `build-kernel/core.4073111`, binary `bin/cens-allkey`, MLIR
`bench-allkey/out-allkey-a.mlir`) — an ALL-keyed binary had never been
EXECUTED at self-compile scale before (the M-era keyed gates ran the
CORPUS keyed, and Run F/J ran SELECTIVE-keyed binaries green). So
all-globals keying is cheap but carries a latent miscompile that
selective keying does not hit. VERDICT: whitelist stays the shipping
mechanism; E11 key-on-conflict is the whitelist-free path (its fork
population is far smaller and closer in character to the proven
selective mode); the all-keyed segfault is a separate root-cause
campaign (unbudgeted — likely another first-activation latent bug of the
E9-family class; the core + binary + deterministic MLIR are preserved
for it).

**ALL-KEYED SIGSEGV ROOT-CAUSED (2026-07-20): record-field boxedness
split under fine keying — a NEW AbiCloning REP-consistency bug, NOT in
shipping mode.** Deterministic crash at `Terminal_Main_lambda_9872$cap+62`
(`mov (%rsi),%eax` with `rsi=0x9` — raw int 9 dereferenced as a heap
pointer), reached via a `Unify`/`Solve` recursion (`10088→9900→9872`).
`9872$cap`'s MLIR body is BYTE-IDENTICAL to the default build's
equivalent (`9354`) — the CODE is correct; the DATA is poisoned. `rsi` =
the captured `%desc1Props`, a solver `Descriptor` (`record:4:i:v:v:v`),
captured in `Unify.merge` as `project.record(%props){field 0}`. The
consumer expects `props.field0` BOXED (nested Descriptor `v`); it arrived
UNBOXED i64 = 9 (a rank/mark/var-id). Corroboration: a sibling keyed
closure `Compiler_Type_Solve_lambda_38358` carries an unboxed-Int capture
slot (decoded header max_values=3, slot 1 = PK_Int). CLASS = same
REP-boundary family as the Tier-1 CNumber cons crash (a scalar settling
UNBOXED on one side, read BOXED on the other) but on a RECORD FIELD /
closure capture, not a kernel ABI: all-globals keying forks the spec key
finely enough that two specs of the same record type get divergent
field-kind (i vs v) layouts and a value crosses between them. Latent
under selective keying (the solver record types are never forked there —
all Tier-1/whitelist gates green). BEARING ON E11 (user's question,
answered): "all-keyable ⇒ subset-safe" — the crash REFUTES the antecedent
(all globals are NOT currently keyable), so the implication does not
carry. But E11's narrow singleton-triggered forking touches the SAME
AbiCloning machinery and could trip the same class. SEQUENCING: fix this
record-field boxedness-consistency hole (or add the analogous
decline/guard the cons case used) BEFORE/ALONGSIDE E11, and land E11 with
the `keyOnConflictForks` counter + self-compile gate (which would have
caught this). Next drill-down if E11 is scheduled: the exact AbiCloning
decision that flips the field kind (is it a single guardable site like
the CNumber case?). Artifacts: `bench-allkey/`, `bin/allkey-bin`,
`bin/allkey-text.mlir`, `core.4078617`.

**DETECTION EXPERIMENT (2026-07-20) — the crash is NEARLY-ISOLATED to
self-compile; a mono-type validator cannot gate it.** Extended
`ValidateLayout` with closure-capture + call-arg interior-boxedness
checks and ran the corpus under all-globals keying:
- **Full corpus PASSES 1625/1625 under all-globals keying with
  validation OFF** — no small test miscompiles or crashes at runtime.
  All-globals keying is very nearly correct; the ONLY known failure is
  the self-compile SIGSEGV (the solver Unify/Descriptor pattern at
  scale). This materially LOWERS the risk read for E11's far narrower
  forking.
- With validation ON, the check fired on exactly 2 tests
  (`TupleSlotBoxingRecord{Single,Multi}Test`) — but both produce CORRECT
  output at runtime ("[1,1]"): **false positives.** They are benign
  `idx:Int` (producer) vs `idx:erased` (polymorphic pass-through
  consumer) record-field disagreements that codegen handles; the erased
  consumer never derefs the field. A per-node boxedness check cannot
  distinguish this benign erased-vs-concrete case from the malign
  concrete-raw-vs-concrete-boxed one, and the real self-compile crash
  never surfaces as a call-boundary field flip (boxedness check = 0 on
  the all-keyed self-compile). Shipping config: clean (the
  erased-vs-concrete pattern is keying-specific).
- CONCLUSION: the checks were REMOVED (`ValidateLayout` restored to its
  3 sound checks with a doc note). MONO_029 is enforced by ENGINE
  connectivity (R1/R2), not a per-node validator — exactly because the
  keying disagreement is erased-vs-concrete (benign, ubiquitous)
  statically and raw-vs-boxed only at runtime. Fixing the self-compile
  crash needs RUNTIME localization at scale (trace the raw-9 to its
  producing spec / the keyed spec-routing link), not a static gate.
  E11 remains gateable by the all-globals-corpus-clean + self-compile
  green criteria, plus the `keyOnConflictForks` census.

**RUNTIME TRACE — ROOT CAUSE PINNED (2026-07-20, gdb on the deterministic
all-keyed reproducer; every claim is trace evidence, no speculation).**
Crash `Terminal_Main_lambda_9872$cap+62`, `mov (%rsi)` with `rsi=0x9`
(raw int dereferenced as a pointer). Trace chain:
- `9872` is `Unify.merge`'s continuation. rsi = its capture `desc1Props`
  = `props.desc1` = `9`. The closure header (`0x144`) decodes
  n_values=4, max_values=5, **unboxed bitmap = 0 (all captures BOXED)** —
  so builder and evaluator AGREE the slot is boxed; the value is wrong.
- `props` (`merge`'s `Context` argument, `0x10302275570`) is byte-for-byte
  a `Descriptor`: `{field0=9 (rank), field1=0x1800000004 (mark = noMark),
  field2/3 = ptrs}` — identical shape to the known-valid `content`
  Descriptor (`rank=25, mark=noMark`). So **a `Descriptor` value is in
  the `Context` slot.**
- Caller chain (conditional breakpoint on `merge` when `props.field1 ==
  noMark`): `actuallyUnify → unifyStructure → lambda_9877 → merge`, all
  carrying the Descriptor in their `Context`-typed parameter. `9877` is
  built in `unifyStructure`.
- `Context {var1, desc1, var2, desc2}` and `Descriptor {content, rank,
  mark, copy}` are DISTINCT 4-field records (distinct field names → distinct
  spec keys AND layout keys). So this is a genuine wrong-object cross, not a
  same-layout reinterpretation.
ROOT CAUSE: **all-globals keying routes a `Descriptor` value into
`merge`'s `Context` parameter; `merge` reads the Descriptor's unboxed
`rank` (Int 9) as `Context.desc1` (a boxed pointer) and dereferences it.**
MECHANISM PINNED TO CLOSURE DISPATCH, NOT THE REGISTRY: a precise
conflation probe was added to `Registry.updateRegistryType` +
`getOrCreateSpecIdKeyed` (`structurallyIncompatible` — crash iff a spec's
stored type changes to a structurally-different CONCRETE type, excluding
benign erased-vs-concrete refinement; verified shipping-clean, it does NOT
false-positive on the routine `Unit→erased` demand updates). Under
all-globals keying the probe **did NOT fire, yet the produced binary still
SIGSEGVs** — so `Context` and `Descriptor` keep SEPARATE specs and the
cross is NOT a spec-type conflation. The Descriptor crosses into the
Context slot via **keyed CLOSURE DISPATCH / value-routing** (two
continuations sharing a lambda-set-derived dispatch identity, one carrying
a Descriptor). Two precise, structurally-sound, shipping-clean probes were then run to
localize the compiler mechanism (each: crash iff two views are genuinely
different CONCRETE types — record/custom/tuple identity — excluding benign
erased-vs-concrete; the naive layout-key version false-positived on
`Json.Decode.succeed`'s routine `Unit→erased` refinement, so both use an
erasure-tolerant `structurallyIncompatible`):
- **Spec registry** (`updateRegistryType` + `getOrCreateSpecIdKeyed`):
  clean on shipping; under all-keyed it did NOT fire yet the produced
  binary STILL SIGSEGVs → **RULED OUT** (Context/Descriptor keep separate
  specs; not a spec-type change).
- **AbiCloning stamp grouping** (`joinGroup` — the `eqLayout`
  same-signature unification that shares one stamped representative):
  clean on shipping; under all-keyed it did NOT fire yet the produced
  binary STILL SIGSEGVs → **RULED OUT** (no two structurally-different
  closures share a stamp group).
Both probes were reverted after ruling out their mechanisms (diagnostic
scaffolding, not hot-path guards). CONCLUSION (evidence, not speculation):
the conflation is NEITHER a spec-type conflation NOR a stamp-representative
share — it is a pure **VALUE cross**, a `Descriptor` value placed into a
`Context`-typed slot with NO type-level record (every spec/stamp keeps the
two types correctly separate). Remaining candidate: closure CONSTRUCTION /
value routing — a `papCreate` capturing a value whose runtime type
(Descriptor) differs from its declared slot type (Context), most plausibly
via a keyed erased-container (IORef/Array of Descriptors) whose element
type erases such that a Descriptor read is bound into a Context position.
Next instrument: watchpoint the specific Context SSA that first receives a
Descriptor (trace up the `actuallyUnify`/`unifyStructure` value chain past
`makeContext`), or instrument closure-capture construction to flag a
captured value whose runtime tag ≠ its declared capture type. Artifacts:
`bin/eco-compiler-probe`, `bin/eco-compiler-stamp`, `bin/stamp.mlir`,
`/tmp/trace{1,2,3,4}.out`, `/tmp/stamp-run2.txt`.

**ROOT CAUSE FOUND (2026-07-20, bpftrace uprobes + one-shot gdb + MLIR +
source; every link direct evidence): AbiCloning singleton-REPRESENTATIVE
hijack — LSS_009's "interchangeable representative" premise is violated by
keyed clones.** The decisive instrument was a `sudo bpftrace` uprobe on
`eco_alloc_closure_k` with an in-kernel arg0 filter (the step gdb stalled
42+ min on ran in ~18 s wall over 27,561,458 alloc events): **the crashing
"9877 closure" was NEVER BUILT** — zero allocs with 9877's wrapper across
the whole run — and `9877$cap` executes exactly once: the crash. The object
actually flowing is a genuine **`lambda_9878` closure** (gdb one-shot at
`10088$cap+0xab`: evaluator `wrapper_9878$cap`, captures c0=content,
c1=`0x10302275570` the Descriptor — LEGITIMATE for 9878's own signature).
Mechanism, MLIR-confirmed (`allkey-text.mlir` lines cited in
`debug-context.md`): `unifyStructure`'s branches build per-key continuations
(9877 br-A ctx-capturing / 9878 br-B desc-capturing) and per-key
`Unify.andThen` clones (`_$_11371`/`_$_11373`) with per-key inner handlers
(`lambda_10088` singleton_fast→9877 / `lambda_10084` singleton_fast→9878) —
all correct — but BOTH chains converge on ONE
`System_TypeCheck_IO_andThen_$_11397` (both 10088-PAP and 10084-PAP carry
the SAME lambda-set member, since members are minted per SOURCE lambda —
`LssInfer.elm:141-148` `srcLambdaKey` — and 10084/10088 are keyed clones of
one source lambda → same singleton → same keyed-spec key → shared clone).
Its inner `lambda_9900`'s dispatch is stamped `singleton_fast →
@lambda_10088$cap`; **no `singleton_fast → 10084$cap` exists in the entire
program** (grep). The stamp comes from `AbiCloning.joinGroup`
(`AbiCloning.elm:403-422`) merging same-member same-signature-layout
instances into one `LayoutGroup`, DISCARDING the second `lambdaId` (`rep` =
first in walk order; `unanimous` = capture-LAYOUT agreement only), and
`resolveInGroups` (:1167-1175) stamping `g.rep` for the site. Sound when
multi-instance members are verbatim copies (inliner copies etc. — the
shipping population); UNSOUND under keying, where clones are
layout-identical but behaviorally divergent. Runtime asymmetry seals it
(trace11 counts to crash): `built9878=1, built9877=0, calls10084=0,
calls9878=0, calls10088=1, calls9877=1` — the 9878 chain's own code never
runs; TWO layout-clean hijacks (10084-PAP read as 10088-PAP `[value]`, then
9878 closure read as 9877 closure `[value,value]`) deliver 9878's
Descriptor capture into `merge`'s Context param. SCOPE CORRECTION: the
earlier "stamp grouping RULED OUT" probe crashed only on STRUCTURALLY
different groupings — 10084/10088 are structurally identical, so it
correctly stayed silent while this mechanism was live; the earlier
"record-field boxedness split" hypothesis is RETIRED (boxedness was never
inconsistent — the value is simply the wrong object). Why self-compile
only: requires ≥2 same-layout keyed clones of one source lambda flowing
into a SHARED downstream keyed spec's singleton site (nested-HOF
Unify.andThen-over-IO.andThen multi-branch shape; corpus lacks it —
1625/1625 keyed-green). FIX OPTIONS (pending): **A (minimal)** — track
distinct lambdaIds per LayoutGroup (dedup same-id re-encounters) and
Decline all stamp arms on ≥2 distinct instances unless bodies verbatim-eq;
step 0 = `declinedMultiInstance` census on shipping (byte-identity gate)
and all-keyed. **B (architectural, E11-era)** — fork-qualified member ids:
keyed clones mint distinct members, sets stay honest (no false singleton)
AND downstream HOFs fork per member, legitimately recovering the devirt;
needs member minting to see the enclosing keyed spec (LssInfer is per-unit
pre-fork today). E11 bearing: its singleton-triggered forking creates
exactly this clone population, so the fix (either) is a PREREQUISITE; the
`keyOnConflictForks`+self-compile gate stands. **DECISION (2026-07-20,
user): Fix B. Detailed design ready at
`plans/lss-fork-qualified-members.md`** (qualified id = interned
`l|lam|specId` via the existing memberIdFor table; qualification gated on
the defining global's keyed routing; spec identity threaded via
ItemAux.currentSpecId — S is at the 32-slot cap; signature-baked members
stay raw = unstampable-but-sound; Fix A's multi-instance check retained as
the standing census probe `multiInstanceGroups == 0`; milestones B0-B4,
gate = the debug-context repro green + §7 grep gates; B3 re-opens the
"does E11 still pay?" question if all-globals keying lands sound+cheap). Fast-resume digest with
methodology notes (ASLR-proof bpftrace base trick, mid-function-offset
limitation, tracefs mount): `debug-context.md`; scripts trace9/10/11 in the
session scratchpad.

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

---

## 12. OPEN-QUESTIONS CENSUS — ALL SETTLED (2026-07-21): `/work/census.md`

One campaign closed every open census question in this plan. Verdicts
(full evidence in census.md; permanent report-only instruments added to
LssStats/AbiCloningStats behind ECO_MONO_LSS_REPORT):

- **E10.0:** `declinedUnsettled` = 0 (guards decline zero sites) — E10 is
  hygiene only. The §11.7 keyed devirtKernel −20 delta is consult-population
  drift, NOT guard declines (hypothesis refuted).
- **Whitelist growth: CLOSED** — largest candidate `Basics.not` = 0.025 % of
  dispatch; `Scheduler.*` never dispatches. List.cons was the only prize.
- **Over-apply residue (staged v3): CLOSED** — statically flat (top member
  21 sites), top-20 members' reps carry 258 sat total.
- **E3: definitively CLOSED** — 2 multi-set consulted sites in the whole
  self-compile, 0 dynamic events.
- **E8 sizing:** within-LSS precision headroom EXHAUSTED — the 641.7 M
  residual gen is ⊤-through-locals/escape (E8-or-nothing); LTop callee
  shapes: local=7,248 vs recordAccess=28 (globals/kernels are direct-call).
- **ABI floor:** ~40 M fast calls/run expectation (bounds 4–77 %) — real but
  LOW priority (Run O: call overhead is wall-neutral here).
- **E7:** trigger never fired (`stampedWrapperInstances=0`).
- **E9.4: DEPRIORITIZED** — cons alloc call = 0.06 % of wall. The profile's
  REAL heap-side levers (new): `Allocator::resolve` 11.5 % (measure P2
  `--inline-deref`) and `eco_gc_push_stack_range` 5.1 % (post-E1.3-inline
  coalescing target).
