# Wide Direct-ABI Statepoint Fix — Plan

## 0. Goal

Stop the `gc.statepoint`-with-wide-struct-return assertion crash in LLVM
SelectionDAG that breaks `MVarReadDoesNotEmptyTest` and any other Elm
code returning a wide all-primitive aggregate from a cross-specialised
function.

The proximate cause is `chooseResultAbi`
(`runtime/src/codegen/Passes/EcoUnboxedAggCrossSpec.cpp:142-148`)
routing all-primitive aggregates of *any* size through the Direct ABI
(LLVM multi-result struct return). For wide structs, RS4GC wraps the
call in `gc.statepoint` and `gc.result.sl_*`, and LLVM's
`StatepointLowering::lowerCallFromStatepointLoweringInfo` hits the
`CallEnd->getOpcode() == ISD::CALLSEQ_END` assertion when walking the
chain past the `CopyFromReg` nodes that materialise each struct field.

Two-phase work:

- **Phase A — Diagnosis.** Find the exact field-count threshold N at
  which LLVM's StatepointLowering starts failing. Write minimal
  hand-rolled LLVM IR fixtures with `gc.statepoint` calls returning
  `{i64}`, `{i64, i64}`, `{i64, i64, i64}`, … up to ~8 fields. Run
  each through `eco-boot-native` (which uses the same SelectionDAG
  path as the test runner) and find the smallest N that asserts.
- **Phase B — Fix.** Based on the threshold, pick one of:
  - **Fix 1:** Cap Direct ABI at N-1 fields; demote wider all-primitive
    aggregates to Boxed.
  - **Fix 2:** Cap Direct ABI at N-1 fields; route wider all-primitive
    aggregates through the existing Sret machinery.

  The choice depends on the threshold:
  - If N is **low** (e.g., 4), wide records are common in Elm code,
    losing the optimisation via Fix 1 would be a meaningful regression
    → choose Fix 2.
  - If N is **high** (e.g., 7+), wide records are rare, so Fix 1 is
    fine and the smaller change wins.

## 1. Background — what's happening

`MVarReadDoesNotEmptyTest` returns a `Readings` record with 6 `Int`
fields. Cross-spec's `chooseResultAbi` sees an aggregate with no
`!eco.value` elements and assigns `ResultAbi::Direct`. The worker is
emitted with a multi-result `func.func` signature, which
`populateFuncToLLVMConversionPatterns` packs into an LLVM struct
return on the `llvm.func` (LLVM IR has no multi-return). RS4GC then
wraps the wrapper's call to the worker in `gc.statepoint`, and the
result is extracted via `gc.result.sl_i64i64i64i64i64i64s` — a
6-element struct-returning intrinsic.

Concrete IR shape from the post-RS4GC dump (`/tmp/mvar_post.ll:2089-2096`):

```
%token = call token (...) @llvm.experimental.gc.statepoint.p0(...,
    ptr elementtype({ i64, i64, i64, i64, i64, i64 } (i64,...,i64))
    @"lambda_21$cap$unboxed", ...)
%7 = call { i64, i64, i64, i64, i64, i64 }
       @llvm.experimental.gc.result.sl_i64i64i64i64i64i64s(token %token)
%8  = extractvalue { i64, i64, i64, i64, i64, i64 } %7, 0
... (6 extractvalues) ...
```

SelectionDAG lowering of this statepoint asserts at
`StatepointLowering.cpp:354`:

```
Assertion `CallEnd->getOpcode() == ISD::CALLSEQ_END && "expected!"' failed.
```

The assertion fires because the lowering walks the chain *immediately
after* the lowered call and expects `CALLSEQ_END`; for a struct-returning
call SelectionDAG emits multiple `CopyFromReg` nodes (one per struct
field) between the call and CALLSEQ_END, breaking the walker's
assumption.

**Reproduction is independent of the JIT pipeline.** Both
`eco-boot-native` (AOT) and `EcoRunner` (JIT) reach SelectionDAG with
the same IR shape and both crash. `ecoc -emit=llvm` doesn't reach
SelectionDAG (text-IR dump only) and so doesn't reproduce.

## 2. Out of scope

- Patching LLVM itself (`StatepointLowering`). The upstream fix would
  walk past `CopyFromReg` chains before checking for `CALLSEQ_END`;
  carrying that as an out-of-tree LLVM patch is a maintenance burden
  this plan doesn't take on.
- The `MVarReadDoesNotEmptyTest` `CallEnd` failure is the one we'll
  test for. Other tests (`ProcessSpawnRecursive`, `ProcessYieldThrashing`,
  `TaskOnErrorCascade`) failed under my earlier `wrapper-fca-fix.md`
  changes — those were separate FCA-of-gc-ptr failures and remain
  out-of-scope for this plan (handled by `wrapper-fca-fix.md`).
- Cons ABI handling. Cons is always Boxed per current `chooseResultAbi`
  (`shape.kind == LogicalShape::Cons` falls through to non-aggregate
  treatment); it's not affected by this work.

## 3. Phase A — Diagnose the threshold

### A.1 Fixture format

Write minimal hand-rolled LLVM IR files in `/tmp/`:

```
/tmp/statepoint-struct-1.ll  ; struct return with 1 field
/tmp/statepoint-struct-2.ll  ;                     2
/tmp/statepoint-struct-3.ll  ;                     3
…
/tmp/statepoint-struct-8.ll  ;                     8
```

Each fixture has the minimal shape that reproduces the failure mode:
a function with `gc "eco-gc"` that calls another function returning
`{i64, ..., i64}` via `gc.statepoint`. Concretely (for N=4):

```llvm
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

declare token @llvm.experimental.gc.statepoint.p0(i64, i32, ptr, i32, i32, ...)
declare { i64, i64, i64, i64 } @llvm.experimental.gc.result.sl_i64i64i64i64s(token)

define { i64, i64, i64, i64 } @callee() gc "eco-gc" {
  %r = insertvalue { i64, i64, i64, i64 } poison, i64 1, 0
  %s = insertvalue { i64, i64, i64, i64 } %r, i64 2, 1
  %t = insertvalue { i64, i64, i64, i64 } %s, i64 3, 2
  %u = insertvalue { i64, i64, i64, i64 } %t, i64 4, 3
  ret { i64, i64, i64, i64 } %u
}

define i64 @caller() gc "eco-gc" {
  %tok = call token (i64, i32, ptr, i32, i32, ...)
      @llvm.experimental.gc.statepoint.p0(i64 0, i32 0,
          ptr elementtype({ i64, i64, i64, i64 } ()) @callee,
          i32 0, i32 0, i32 0, i32 0)
  %res = call { i64, i64, i64, i64 }
      @llvm.experimental.gc.result.sl_i64i64i64i64s(token %tok)
  %x = extractvalue { i64, i64, i64, i64 } %res, 0
  ret i64 %x
}
```

The DataLayout + triple lines and the `gc "eco-gc"` attribute are
required so RS4GC will process the function. `gc-live` bundle and
relocates aren't needed — the goal is the call-result lowering, not
relocation logic.

### A.2 Lowering driver

Neither `ecoc` nor `eco-boot-native` parses `.ll` today — both go
through `parseSourceFile<ModuleOp>(...)` and expect MLIR. So the
fixtures need one of:

- **(Preferred)** Translate `.ll` → MLIR `llvm` dialect with
  `mlir-translate --import-llvm`, then feed to `ecoc -emit=jit`
  (which runs the same SelectionDAG lowering path as the test
  runner — `ecoc -emit=llvm` stops one phase too early, before
  SelectionDAG, and won't trigger the assertion).
- **(Fallback)** Hand-roll the fixtures directly as MLIR `llvm`
  dialect; same `ecoc -emit=jit` drive. Slightly more verbose
  syntax but no translate step.
- **(Last resort)** Small standalone C++ harness in
  `tests/codegen/` that uses `llvm::parseIRFile` + the same
  `addEcoGCPipeline` and codegen path as `ecoc`. Use only if
  `mlir-translate --import-llvm` can't produce a faithful round-trip
  (e.g., loses the `gc "eco-gc"` attribute or the statepoint
  bundles).

Why `ecoc -emit=jit` rather than `eco-boot-native`:
- Both register `eco-gc` and run RS4GC.
- `ecoc -emit=jit` runs SelectionDAG through the JIT path, which is
  exactly what the test runner does — most faithful reproduction.
- `eco-boot-native` runs SelectionDAG through the AOT object-emit
  path; equally good for diagnosis if `ecoc -emit=jit` runs into
  unrelated issues, since both should hit the same assertion.

### A.3 Sweep procedure

```bash
for n in 1 2 3 4 5 6 7 8; do
    echo "=== N=$n ==="
    mlir-translate --import-llvm /tmp/statepoint-struct-$n.ll \
        > /tmp/statepoint-struct-$n.mlir
    ./build/runtime/src/codegen/ecoc -emit=jit \
        /tmp/statepoint-struct-$n.mlir 2>&1 | head -5
done
```

Expected outcomes (hypotheses to verify):
- **N=1**: passes (single-field struct return is the simple case).
- **N=2 or N=3**: passes (existing Tuple2/Tuple3 work uses this and
  hasn't shown problems).
- **N=4, 5, 6**: at some point starts failing; the smallest failing
  N is the threshold.

### A.4 Record the threshold

Capture the smallest N that asserts as `kMinFailingDirectFields`.
Then `kMaxDirectFields = kMinFailingDirectFields - 1` is the largest
field count Direct ABI can safely produce.

### A.5 Decision point

- **If `kMinFailingDirectFields >= 7`:** Fix 1 is acceptable (only
  records with ≥7 fields would lose Direct optimisation, which is
  rare in Elm code).
- **If `kMinFailingDirectFields <= 6`:** Fix 2 is preferred — wide
  records are common enough that losing the optimisation matters.

## 4. Phase B — Implement the fix

### B.1 Fix 1 (if chosen): cap Direct ABI by field count

**File:** `runtime/src/codegen/Passes/EcoUnboxedAggCrossSpec.cpp:142-148`

```cpp
static ResultAbi chooseResultAbi(const LogicalShape &shape) {
    if (!shape.isAggregate()) return ResultAbi::Boxed;
    for (Type t : shape.elementTys)
        if (isa<eco::ValueType>(t)) return ResultAbi::Sret;
    // LLVM SelectionDAG StatepointLowering can't lower gc.statepoint
    // calls returning wide LLVM structs (the CALLSEQ_END walker trips
    // on the CopyFromReg chain for struct results > kMaxDirectFields).
    // Wider all-primitive aggregates demote to Boxed.
    constexpr unsigned kMaxDirectFields = /* from Phase A */;
    if (shape.elementTys.size() > kMaxDirectFields)
        return ResultAbi::Boxed;
    return ResultAbi::Direct;
}
```

Effect: aggregates with more than `kMaxDirectFields` primitive elements
stay boxed (no cross-spec promotion). The wrapper is never built; the
worker is never emitted; callers continue to use the original boxed
ABI.

### B.2 Fix 2 (if chosen): route wide records through Sret

**File:** `runtime/src/codegen/Passes/EcoUnboxedAggCrossSpec.cpp:142-148`

```cpp
static ResultAbi chooseResultAbi(const LogicalShape &shape) {
    if (!shape.isAggregate()) return ResultAbi::Boxed;
    for (Type t : shape.elementTys)
        if (isa<eco::ValueType>(t)) return ResultAbi::Sret;
    // LLVM SelectionDAG can't handle gc.statepoint calls returning wide
    // LLVM structs. Narrow all-primitive aggregates use Direct (LLVM
    // multi-return packing); wider ones use Sret instead, which carries
    // the result through a caller-allocated `!llvm.struct` slot and
    // doesn't put a struct return on the statepoint at all.
    constexpr unsigned kMaxDirectFields = /* from Phase A */;
    if (shape.elementTys.size() > kMaxDirectFields)
        return ResultAbi::Sret;
    return ResultAbi::Direct;
}
```

Effect: wide all-primitive aggregates flow through the same Sret
machinery as mixed-element ones — wrapper allocates a slot, worker
stores into it field-by-field, no struct return crosses the
statepoint boundary.

**Prerequisite:** verify the Sret path tolerates all-primitive
element types. Today the path is reached only when at least one
element is `!eco.value` (per the existing `chooseResultAbi`), so
all-primitive Sret is an untested combination. The slot allocation
(`replaceBodyWithWrapper`) uses `sretSlotStructTy` which builds the
slot's LLVM struct type from `elementTys`; for all-primitive elements
it produces `<{ i64, i64, ... }>` or similar — that's structurally
fine, and the GEP+store/GEP+load helpers (`emitSretStore`,
`emitSretLoad`) dispatch per element type, including the primitive
branches. The main risk is paths that special-case `!eco.value`
elements and may produce wrong code (or assertions) when no such
element is present. Audit during implementation.

**Audit fallback:** if the audit (B.5) shows the Sret path can't
handle all-primitive elements without significant changes (e.g.,
multiple sites assume at least one `!eco.value` element), we
abandon Fix 2 and fall back to Fix 1 (Boxed demotion) even if the
threshold is low. Document the audit outcome in the commit message.

### B.3 Tests

1. **Full E2E (all tests).** `cmake --build build --target full` —
   the gate is `MVarReadDoesNotEmptyTest` going green, and **every
   other E2E test must continue to pass**. Do not just spot-check
   the target test: read the full output and confirm no regression.
   Run with no `TEST_FILTER` so the entire suite executes.
2. **Stage 7 self-compile** (`guides/bootstrap.md`) — sanity check that
   the eco compiler bootstrap still cleanly self-compiles. The
   bootstrap has many cross-specialised functions; any regression
   here would surface as a Stage 7 crash.
3. **New fixture (Fix 1 path):**
   `test/codegen/wide_all_prim_record_demotes.mlir` — MLIR fixture
   with a function whose `eco.logical_result_types` declares an
   all-primitive record with > `kMaxDirectFields` fields. FileCheck
   asserts the function did NOT get a `$unboxed` worker (cross-spec
   demoted it).
4. **New fixture (Fix 2 path):**
   `test/codegen/wide_all_prim_record_sret.mlir` — same input. FileCheck
   asserts the worker exists with a leading `!llvm.ptr` sret outparam
   and no struct return type.
5. **Diagnosis fixtures kept in tree (permanent).** The Phase A
   `.ll` fixtures get a permanent home — e.g.
   `test/codegen/llvm-statepoint-struct-return-{N}.ll` for N=1..8 —
   so they can be re-run against future LLVM versions to detect when
   the SelectionDAG bug is fixed upstream (which would let us raise
   `kMaxDirectFields`). Each fixture is annotated with its expected
   status under the current LLVM (passes / asserts). Hook into
   whichever existing codegen-test harness is most natural (run via
   `mlir-translate --import-llvm` + `ecoc -emit=jit`, or via the
   small C++ harness if that path was taken in A.2).

### B.4 Invariant updates

**File:** `design_docs/invariants.csv`

- **CGEN_064** (UnboxedWorkerTag): add a clause to the existing list
  of ABI decision rules:
  ```
  ; Direct ABI is capped at kMaxDirectFields elements
  ; (currently <value>); wider all-primitive aggregates use
  ; <Boxed | Sret> instead, because LLVM SelectionDAG
  ; StatepointLowering can't lower gc.statepoint calls whose callee
  ; returns wider LLVM structs (CallEnd != CALLSEQ_END assertion at
  ; StatepointLowering.cpp:354).
  ```
- **REP_AGG_001** (ValueAggregates): no change needed (the field-count
  cap doesn't affect representation, only ABI selection).

### B.5 (Fix 2 only) Audit Sret path for all-primitive elements

Per B.2 prerequisite. Specific sites to check in
`EcoUnboxedAggCrossSpec.cpp`:

- `sretSlotStructTy` (search for definition): does it produce a valid
  `!llvm.struct` for all-primitive `elementTys`?
- `emitSretStore` / `emitSretLoad`: per-element dispatch — verify the
  primitive branches are correct in isolation (without any
  `!eco.value` element present).
- `replaceBodyWithWrapper` Sret branch (`:1456-1505`): the
  rebuild-via-`eco.make.*` and then-`eco.to_heap` step — confirm
  it handles all-primitive `loadedFields` (in principle yes, since
  `eco.make.tuple2/3/record/custom` accept any element types).
- `cloneAsWorker`'s sret-store-before-return rewriter (around
  `:1311-1333`): the per-element store loop dispatches by `elementTy`
  — primitive branches must produce correct LLVM stores.

## 5. Verification

Mandatory:

1. `cmake --build build --target full` — **full E2E suite**, no
   filter. `MVarReadDoesNotEmptyTest` must be green and every other
   test that was green before this change must remain green. Compare
   the new failure list against the pre-change failure list (the 3
   FCA failures from `wrapper-fca-fix.md`) and fail verification on
   any new regression.
2. Stage 7 self-compile (`guides/bootstrap.md`).

Bonus:

3. Stage 8 fixed-point bootstrap.
4. Re-run failing tests from `wrapper-fca-fix.md` (3 FCA failures) to
   confirm they're still failing on their own issue and not on this
   one. (These will only be fixable when `wrapper-fca-fix.md`'s
   deferred chunks land.)

## 6. Effort estimate

| Phase / Step | LOC est. | Risk |
|---|---|---|
| A.1–A.5 Diagnosis | ~80 lines fixture IR + 1 small driver script | Low. Mechanical. |
| B.1 Fix 1 | ~5 lines cpp | Trivial if chosen. |
| B.2 Fix 2 | ~10 lines cpp + small Sret audit | Low–medium. Audit is the variable. |
| B.3 Tests | ~50 LOC fixture per fix path | Low. |
| B.4 Invariants | ~3 lines csv | Trivial. |
| B.5 Sret audit (Fix 2 only) | 0 LOC if clean; up to ~30 LOC if a path needs widening | Variable. |

Total: ~10–50 LOC compiler C++ + ~150 LOC fixtures.

## 7. Out of scope follow-ups

- **Patch LLVM `StatepointLowering`** to handle wide struct returns
  correctly. Right answer architecturally but means carrying an
  out-of-tree LLVM patch. Revisit if other LLVM patches accumulate
  for unrelated reasons and an out-of-tree fork becomes attractive
  anyway.
- **Re-tune `kMaxDirectFields`** if LLVM is upgraded. The diagnosis
  fixtures from Phase A are the regression test — if a future LLVM
  version raises the supported field count, the constant can be
  bumped. Documented in CGEN_064.

## 8. Resolved open questions

1. **Does `ecoc` accept `.ll`?** No. Both `ecoc` and `eco-boot-native`
   parse MLIR via `parseSourceFile<ModuleOp>`; neither has an `.ll`
   path. `ecoc` is the more general driver (multiple `-emit=` modes;
   used for the JIT path that reproduces the SelectionDAG crash);
   `eco-boot-native` is the AOT object-emit driver. Path forward
   is `mlir-translate --import-llvm` → `ecoc -emit=jit`, with
   hand-rolled MLIR `llvm` dialect or a small C++ harness as
   fallbacks (per A.2).
2. **Diagnosis-first ordering.** Confirmed; pick Fix 1 vs Fix 2
   only after Phase A produces a threshold.
3. **Sret all-primitive audit.** Confirmed: audit during B.5; if the
   path can't be made to work without significant surgery, abandon
   Fix 2 and fall back to Fix 1 (per B.2 "Audit fallback").
4. **Permanent Phase-A fixtures.** Confirmed; the
   `llvm-statepoint-struct-return-{N}.ll` fixtures stay in tree as
   LLVM-version regression probes (B.3 item 5).
5. **Cons.** Confirmed out of scope; Cons remains Boxed.
6. **Post-fix testing.** Confirmed: run the **full** E2E suite
   (`cmake --build build --target full` with no `TEST_FILTER`), not
   just the gating test.

## 9. Composition with earlier phases

- **Phase 3.1 (cross-spec eligibility):** unchanged; only the ABI
  decision in `chooseResultAbi` shifts.
- **Phase 3.3 (Sret ABI):** unchanged surface. Fix 2 extends Sret's
  eligibility set to include wide all-primitive aggregates;
  mechanically the same code paths.
- **`wrapper-fca-fix.md`:** independent. That plan's deferred chunks
  (the 3 FCA-failure tests) remain blocked on a different RS4GC
  interaction. This plan does not interact with those changes —
  `chooseResultAbi`'s output is consumed by the wrapper/worker
  emission, which is the locus of the FCA fix but is downstream of
  the field-count gate.
