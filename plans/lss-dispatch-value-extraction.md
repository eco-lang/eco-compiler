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
singleton coverage. Remaining E0: E0.5 (`ECO_MONO_LSS_SITES` per-member decline
attribution — rank *which* hot sites are declined and why) + E0.8 (dbg* cleanup).

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

### E2.0 Verify the object-layout premises (before any compiler change)

Three claims to pin, each with a small test, because the whole phase rests on them:

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
3. **Header accounting:** confirm the `n_values`/`max_values` semantics for
   captures-bearing closures (the packed-word docs and `eco_alloc_closure_k`
   (`RuntimeExports.cpp:688–689`) read differently — `n_values=captures?`,
   `max_values=captures+arity?`). The stamped claim is: at a site whose peeled
   callee type takes `n` args, the flowing `m`-PAP has exactly
   `n_values = |m.captures| + k` filled slots, `k = flatArity(m) − n`. Settle this
   by reading the papCreate lowering's header packing and writing the number into
   the invariant text (E2.5).

If any of the three fails, stop and re-derive — the rest of the phase is mechanical
only because of them.

### E2.1 Fences (v1 scope)

Stamp only when ALL hold, else decline into the existing counters:
- singleton `LSet [m]`, instance resolution passes LSS_009 exactly as today;
- the instance is **single-stage** (its type has no nested `MFunction` stage
  structure past the site's application — multi-stage PAP prefixes interact with
  staging segmentation and are v2; count them in a new `declinedShapePapStaged`);
- `k ≥ 1` derived as `flatArity(instance) − siteArgCount`, and
  `siteArgCount == |peeled callee params|` (the site saturates the remainder);
- prefix param kinds pass the same char/unboxability gates as captures do today
  (i16 prefix slots blocked until E4c lands, same `charFree` check).

### E2.2 AbiCloning changes

In the arity-decline path that currently bumps `declinedShapeArity`
(`AbiCloning.elm:1119` helper; the check feeding it sits in the candidate filter
around `:1062`): before declining, attempt the PAP stamp — compute `k`, apply
E2.1's fences, and on success stamp exactly like `stampCall` (`:982–999`) but with
the merged `captureAbi` above. New counters: `stampedPapPrefix`,
`declinedShapePapStaged`; wire both into the `lss globalopt:` line
(`Builder/Generate.elm:911–946`).

### E2.3 Emission marker

`generateFastDispatchCall` needs no functional change (E2's stamp is shape-
compatible). Add one attr for auditability: when the stamp came from the PAP arm,
emit `_pap_prefix = k` (IntegerAttr) on the papExtend (`Expr.elm:1760–1775` attr
block). CallInfo carries it as `fastPapPrefix : Maybe Int` (add to the record at
`AST/Monomorphized.elm:1535–1537`, default `Nothing` in `defaultCallInfo:1553` —
mechanical sweep of the ~10 construction sites the compiler's exhaustiveness will
list).

### E2.4 Tests

- Unit `.mlir` pins from E2.0.
- `test/elm/src/HofPapPrefixDispatchTest.elm` (E2E, solver+LSS config): a 3-arity
  global partially applied with 2 args, the PAP passed through a non-inlinable
  boundary (stored in a record field is NOT eligible — pass as a function argument
  to a `NOINLINE`-shaped consumer, i.e. one whose cost exceeds the inline
  threshold), applied to 1 arg; assert result correctness AND
  `dispatchUpgraded`/`stampedPapPrefix` via the report (grep the compile stderr in
  the harness the way existing `Lss*Test` pins do); a variant with a boxed + an
  unboxed prefix arg under tiny-nursery `ECO_HEAP_VALIDATE`.
- Negative pin: a two-stage member's PAP declines (`declinedShapePapStaged=1`).

### E2.5 Invariant

New `LSS_011`: *"A PAP-prefix stamp (`_pap_prefix = k`) is legal only when the
site's callee annotation is a singleton `LSet [m]`, the resolved instance is
single-stage, `k = flatArity(m) − siteArgs ≥ 1`, and the stamped
`_capture_abi` equals m's capture ABI followed by m's first k param ABIs; the
runtime object at such a site holds exactly |captures|+k filled value slots whose
declared kinds equal that prefix"* — add to `invariants.csv` with the E2.0-settled
header-accounting numbers, tested by the E2.4 pins.

### E2.6 Gate

Gate to build: E0's `declinedShapeArity`-attributed generic events are material
(≥ a few % of Run-B events). Gate to keep: touch-all + `--target full` under
`ECO_MONO_ENGINE=solver` green; elm-tests baseline-identical (12991/12);
`declinedShapeArity` drops in the report; E0 re-census shows the converted sites'
generic events moving to fast rows; interleaved wall A/B; flag-off (subst) builds
byte-identical.

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
4. Can A1's DSU inference match unkeyed solver-LSS singleton counts — globally
   and on E0's hot sites? Which precision-gap classes appear (data-stored arrows
   are the expected one)?
5. Are hot `$cap` bodies inlined at -O2 (E1.1), and what does the Dev tier's
   no-inliner policy cost in day-to-day measurements? (Separate decision:
   whether Dev should gain a cheap inliner.)
6. Does `wrappersInserted` collide with stamped sites on hot paths (E7 trigger)?
7. E2.0(3): what exactly do `n_values`/`max_values` hold for captures-bearing
   closures? (Settles LSS_011's wording.)
