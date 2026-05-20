# Cross-Spec `bridgeOperands` Regressions — Reproduction Fixtures

## 0. Goal

Land three small MLIR-codegen regression fixtures in `test/codegen/` that
each isolate one cross-spec wrapper-generation bug exposed when
[`plans/widen-construct-make-call-aggregates.md`](widen-construct-make-call-aggregates.md)
Phase 1 lifts the `Eco_AnyValue` operand-type restriction. Once these
three fixtures pass, Stage 6 of the bootstrap
(`cmake --build build --target eco-compiler`) is expected to compile the
eco-compiler's own MLIR cleanly.

Background: with Phase 1 in place, Gates A (1429 JIT E2E tests) and B
(702 AOT E2E tests) stay green and the stress suite (100 tests) passes.
Stage 6 still fails. The failure is in
`EcoUnboxedAggCrossSpecPass`'s wrapper-rewrite path, NOT in the
construct/make/call operand-type lift. Three distinct bug classes need
fixtures + fixes.

## 1. Issue inventory

### 1.1 Issue 1 — sret-slot offset in `bridgeOperands`

**Location:** `runtime/src/codegen/Passes/EcoUnboxedAggCrossSpec.cpp:1135`
(lambda) + call site at `:1218`.

**Mechanism:** the lambda iterates `paramShapes[i]` against
`operands[i]` starting at `i = 0`. The caller builds `operands` by
prepending the Sret-slot pointers (each an `!llvm.ptr` from an
`llvm.alloca`) ahead of the actual call arguments. `paramShapes`
describes the actual arguments only. When `paramShapes[0].isAggregate()`
is true and `operands[0]` is a Sret-slot pointer, the loop emits
`eco.from_heap(!llvm.ptr) → !eco.tuple2<...>` — the `eco.from_heap`
verifier rejects the `!llvm.ptr` operand and the pass fails.

**Trigger:** the callee being redirected has *both* a Sret outparam
(its result is an aggregate containing at least one `!eco.value`) *and*
an aggregate parameter on its worker signature. Rare in the small E2E
corpus; common in the eco-compiler's own MLIR (compiler-internal
records of mixed `Int` / `String` / `Custom` fields).

**Diagnostic seen at Stage 6:**
```
error: 'eco.from_heap' op operand #0 must be eco.value, but got '!llvm.ptr'
```
(the cascade headline in `plans/widen-construct-make-call-aggregates.md` §1).

**Fix sketch:** thread `argOffset = sretSlotVals.size()` into the
lambda and dereference `operands[argOffset + i]`.

### 1.2 Issue 2 — missing aggregate→`!eco.value` bridge in `bridgeOperands`

**Location:** same lambda.

**Mechanism:** the loop only handles one direction —
`paramShapes[i].isAggregate()` (`continue` if not). If the callee
stays boxed (`paramShapes[i].kind == Boxed`) but the caller's operand
has already been promoted to an aggregate (because an upstream
eligible call produced an aggregate result there), no bridging is
inserted and the resulting `func.call` carries an
aggregate-typed operand into a `!eco.value` parameter slot.

**Trigger:** inside a worker body, two `eco.call`s where the first
callee was promoted (its `$unboxed` worker now returns an aggregate)
and the second callee was NOT promoted (kept its `!eco.value`
parameter). The aggregate result of the first flows into the boxed
parameter of the second. Happens any time eligibility analysis
admits a producer but rejects a consumer — common with kernel-call
callees, foreign callees, and any function whose param shape conflicts
across call sites.

**Diagnostic seen at Stage 6:**
```
error: 'func.call' op operand type mismatch:
       expected operand type '!eco.value',
       but provided '!eco.record<!eco.value, !eco.value>' for operand number 3
```

**Fix sketch:** add an `else if (isAggSSAType(haveTy))` branch that
inserts `eco.to_heap` to box the operand back to `!eco.value` before
the call.

### 1.3 Issue 3 — nested-aggregate `make.*` result types from `rewriteConstructToMake`

**Location:** `runtime/src/codegen/Passes/EcoUnboxedAggCrossSpec.cpp:994`.

**Mechanism:** `rewriteConstructToMake` derives a `make.record`'s
result `RecordType` from the operand SSA types verbatim. Pre-Phase 1
the `Variadic<Eco_AnyValue>` constraint on `construct.record` rejected
aggregate operands, so the derived element types were always primitive
or `!eco.value`. After Phase 1's widening, a promoted call's aggregate
result can flow into a `construct.record` operand; `rewriteConstructToMake`
then propagates that aggregate type into the make's element types,
producing a *nested* `RecordType` (e.g.
`!eco.record<!eco.tuple2<i64,i64>, !eco.value>`).

The make-op verifier accepts this (operand types match element types).
But downstream the type converter recursively lowers the nested record
to a nested LLVM struct, RS4GC asserts "support for FCA unimplemented"
on the nested FCA containing a `ptr addrspace(1)`, and the 1-level
strip-aggregates pass at `EcoUnboxedAggCrossSpec.cpp:1278-1300` doesn't
recurse to handle it.

**Trigger:** an eligible call's aggregate result flows into a
`construct.record` / `construct.tuple*` / `construct.custom` field
operand inside another eligible function's body.

**Fix options:**
1. **Full fix (Phase 2 territory):** recursive cross-spec ABI
   promotion + recursive strip-aggregates, per
   [`plans/widen-construct-make-call-aggregates.md`](widen-construct-make-call-aggregates.md)
   §9.
2. **Phase 1.5 stopgap:** in `rewriteConstructToMake`, when a field
   has an aggregate SSA type, emit `eco.to_heap` to box it before
   pushing into `elementTypes`. Element types stay flat; the cost is
   one extra heap allocation per nested-aggregate flow site.

## 2. Why Gates A and B don't catch these

Gate A (JIT E2E, 1429 tests) and Gate B (AOT E2E, 702 tests) both
compile small standalone Elm programs that exercise one or two
language features at a time. None contains a function whose signature
*simultaneously* triggers a cross-spec precondition:

- **Issue 1** needs both Sret outparam *and* aggregate parameter on the
  same worker. The E2E corpus has plenty of each in isolation; the
  eco-compiler is the first program where the same function does both.
- **Issue 2** needs two call sites in the same worker body — one to an
  eligible callee whose aggregate result feeds into the other call
  whose callee stays boxed. E2E programs typically don't pipe one
  promoted call's result directly into a kernel-call argument.
- **Issue 3** needs a `construct.*` whose field operand is itself a
  promoted-aggregate call result. Small E2E tests build aggregates
  from primitives or projection results, not from chained worker
  calls.

The eco-compiler's MLIR has all three patterns at high combinatorial
density (compiler-internal record types, chained `Maybe` / `Result`
pipelines, codegen helpers composing records from helper calls), which
is why the bugs surface only at Stage 6.

## 3. Proposed fixtures

Three small `.mlir` fixtures under `test/codegen/`, each engineered to
trigger exactly one of the three patterns. They run through Gate A's
lit suite (`%ecoc %s -emit=mlir-llvm -enable-unboxed-agg`). Each is
**failing today** under the post-Phase-1 build and is expected to pass
once the corresponding cross-spec fix lands.

### 3.1 `test/codegen/cross_spec_sret_plus_aggregate_param.mlir` (Issue 1)

Two functions with `logical_param_types = ["record:2:i:i"]` and
`logical_result_types = ["record:2:i:v"]`. `@outer` calls `@inner`,
forcing cross-spec to redirect the call inside `@outer$unboxed`'s body.
The redirected call's operands array is `[sret_slot, aggregate_param]`
and the lambda mis-aligns.

**FileCheck expectations:**
- both `$unboxed` workers exist;
- no `eco.from_heap` op with `!llvm.ptr` operand;
- the worker call goes through `func.call @inner$unboxed`.

### 3.2 `test/codegen/cross_spec_aggregate_into_boxed_param.mlir` (Issue 2)

Three functions:
- `@make_pair`: promoted, returns `!eco.tuple2<i64,i64>`.
- `@opaque`: kept boxed (no `logical_*_types` attrs).
- `@driver`: a worker that calls `@make_pair` then `@opaque(@make_pair_result)`.

Inside `@driver$unboxed`, the aggregate result of `@make_pair$unboxed`
flows into `@opaque`'s `!eco.value` parameter without bridging.

**FileCheck expectations:**
- `@make_pair$unboxed` and `@driver$unboxed` exist; `@opaque` stays as
  is;
- `eco.to_heap` appears between the two calls;
- the boxed `@opaque` call receives the boxed result.

### 3.3 `test/codegen/cross_spec_nested_make_record_from_construct.mlir` (Issue 3)

Two functions:
- `@make_t`: promoted, returns `!eco.tuple2<i64,i64>`.
- `@make_rec`: promoted, returns `!eco.record<v,v>`; body calls
  `@make_t` then `construct.record(%t, %nil)`.

Cross-spec promotes both. `rewriteConstructToMake` on `@make_rec`'s
construct sees `%t` is aggregate-typed and would build a nested
`RecordMakeOp` if not handled.

**FileCheck expectations:**
- no nested aggregate types appear in the lowered IR
  (`CHECK-NOT: !eco.record<!eco.tuple2`,
   `CHECK-NOT: !llvm.struct<(struct<`);
- the construct lowering goes through the boxed-slot store path
  (`eco_alloc_record_uninit` + `eco_store_record_field`).

## 4. Implementation plan

### Chunk 1 — Land the fixtures as failing tests

For each fixture above, add the `.mlir` file under `test/codegen/`.
If Gate A's lit harness picks them up automatically (any `.mlir` file
in that directory runs through the configured `%ecoc` substitution),
no test-list edits are needed.

Mark each test with the appropriate XFAIL directive — `lit`'s standard
`// XFAIL: *` if the bug is universal. After landing the fixes, flip
to PASS.

### Chunk 2 — Fix Issue 1 (`bridgeOperands` sret offset)

```cpp
auto bridgeOperands = [&](Location loc, OpBuilder &b,
                          const CalleeRedirect &redirect,
                          SmallVectorImpl<Value> &operands,
                          unsigned argOffset) {
    for (unsigned i = 0;
         i < redirect.paramShapes.size() &&
         (argOffset + i) < operands.size();
         ++i) {
        if (!redirect.paramShapes[i].isAggregate()) continue;
        unsigned slot = argOffset + i;
        Type wantedTy = redirect.paramShapes[i].asWorkerType(
            operands[slot].getContext());
        if (operands[slot].getType() == wantedTy) continue;
        auto bridged = b.create<eco::FromHeapOp>(loc, wantedTy,
                                                  operands[slot]);
        operands[slot] = bridged.getResult();
    }
};
```

Caller passes `/*argOffset=*/sretSlotVals.size()`. ~12 LoC including
the call-site update.

### Chunk 3 — Fix Issue 2 (aggregate→`!eco.value` bridge)

Extend the same lambda with a second branch that boxes aggregate
operands when the callee stayed boxed:

```cpp
if (redirect.paramShapes[i].isAggregate()) {
    // existing from_heap path
} else if (isAggSSAType(operands[slot].getType())) {
    auto valueTy = eco::ValueType::get(operands[slot].getContext());
    auto bridged = b.create<eco::ToHeapOp>(
        loc, valueTy, operands[slot], /*live_roots=*/ValueRange{});
    operands[slot] = bridged.getResult();
}
```

`isAggSSAType` recognises the five aggregate dialect types
(tuple2/tuple3/record/custom/cons). ~10 LoC + helper.

### Chunk 4 — Decide Issue 3 (stopgap vs Phase 2)

Pick one of:
- **(a)** Phase 1.5 stopgap: in `rewriteConstructToMake`, walk fields
  and box every aggregate-typed field via `eco.to_heap` before
  recording its type in `elementTypes`. ~20 LoC.
- **(b)** Leave fixture as `XFAIL` and defer to Phase 2.

(a) keeps Stage 6 unblocked at the cost of one extra alloc per
nested-aggregate field site. (b) keeps the IR efficient but punts.
Recommendation: ship (a) so Stage 6 lands now, plan (b)'s removal as
part of Phase 2.

### Chunk 5 — Re-run gates + bootstrap

- `cmake --build build --target full`
- `cmake --build build --target stress`
- `cmake --build build --target run-aot-e2e`
- Bootstrap chain (Stages 1–8) per `guides/bootstrap.md`.

Pre-fix expectation: the three new fixtures fail with the listed
diagnostics; everything else stays green. Post-fix expectation: all
gates plus the bootstrap succeed.

## 5. Risks

- The fixtures may compile cleanly today by coincidence — the
  underlying bug requires specific cross-spec eligibility decisions.
  If a fixture passes pre-fix, refine it (e.g., add another call site
  that forces the consumer's eligibility to be rejected) until it
  reproduces.
- Phase 1.5 stopgap for Issue 3 will allocate where Phase 2 won't —
  acceptable for compiler bring-up, not for production-perf builds.
  Mark the stopgap with a `TODO(phase-2)` comment and a pointer to
  the parent plan.

## 6. Effort

| Chunk | LoC | Risk |
|---|---|---|
| 1 — three fixtures | ~150 | low; mechanical FileCheck |
| 2 — Issue 1 fix | ~12 | low |
| 3 — Issue 2 fix | ~15 | low |
| 4 — Issue 3 stopgap | ~20 | medium; perf cost |
| 5 — gates + bootstrap re-run | — | the verification step |

Total: ~200 LoC + bootstrap re-run.
