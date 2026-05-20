# Wrapper FCA Fix — Plan

> **Implementation status (2026-05-20).** Chunk 2.1 (runtime ABI
> additions + JIT symbol registration + MLIR runtime declarations) is
> **landed and verified**: build is green and the full E2E suite has
> the same pass/fail count as the pre-change baseline (1413 passing).
> Chunks 1, 2.2, 2.3, 3, 4, 5, 6 are **deferred**.
>
> The original status banner attributed the deferred-chunk failures to
> a JIT-only `packFunctionArguments` interaction. That diagnosis was
> incorrect: a 2026-05-20 hand-rolled MLIR sweep (documented in
> §1.0.1) shows the `support for FCA unimplemented` assertion is
> **not JIT-specific** — it fires
> identically in `ecoc --emit=jit`, `ecoc --emit=llvm`, and
> `eco-boot-native --emit=llvm`. The minimum trigger is **any
> `func.func` with more than one result where at least one is
> `!eco.value`** (FuncToLLVM packs multi-results into a single LLVM
> struct return; if the struct carries `ptr addrspace(1)` fields,
> RS4GC's `computeLiveInValues` asserts on the function-exit
> safepoint). `packFunctionArguments` is a red herring: the
> three failing tests' lowered IR almost certainly carried a residual
> FCA-of-GC-ptr value through some path the `-emit=llvm` driver
> happened to fold and the JIT driver did not — but the underlying
> RS4GC limitation is the same in both pipelines.
>
> Consequence for re-land: the diagnostic is much simpler than
> previously thought. **Dump the post-EcoToLLVM MLIR (`ecoc
> --emit=mlir-llvm`) and grep for any `!llvm.struct<(... ptr<1> ...)>`
> typed SSA value — as a function signature element, call result,
> `llvm.insertvalue`/`extractvalue` operand or result, or
> `llvm.return` operand. Every such value is a guaranteed RS4GC
> assertion at the next stage. If zero remain, RS4GC will accept the
> module.** No JIT-vs-AOT bisection needed.
>
> See §8 "Status" at the end for the precise state and next steps.


## 0. Goal

Lift the Phase 3.4 #1 "all-primitive only" gate on `eco.return` result-side
promotion (`EcoUnboxedAggCrossSpec.cpp:570-574` and the symmetric param-side
gate at `:687-694`) so that Elm function bodies returning aggregates with
`!eco.value` element(s) — records, customs, mixed-element tuples — can
reach the sret ABI. The gate currently exists because the wrapper's
intermediate `eco.make.* → eco.to_heap` chain produces a register-form
LLVM struct value (`<{ ptr addrspace(1), … }>`) that, on some shapes,
survives `FoldExtractValuePass` and trips
`RewriteStatepointsForGC`'s "support for FCA unimplemented" assertion.

Three complementary changes, all landed in a single pass:

- **Fix B (lowering-side, Record/Custom).** In `ToHeapOpLowering`,
  reorder the Record and Custom branches so that every `extractvalue`
  from the aggregate operand happens **before** the `eco_alloc_record`
  / `eco_alloc_custom` call. Widening operations stay exactly where
  they are today (i1/i16 zexts in the post-alloc store loop).
- **Fix C (lowering- + runtime-side, Tuple2/Tuple3/Cons).** Decouple
  alloc from field store, Record/Custom-style. Replace
  `eco_alloc_tuple2(i64 a, i64 b, i32 bitmap)` with
  `eco_alloc_tuple2_uninit(i32 bitmap)` + per-field stores via
  `eco_store_tuple_field`/`_i64`/`_f64` helpers; analogous for Tuple3
  and Cons. The compiler emits the alloc, then post-alloc stores with
  the relocated `ptr addrspace(1)` (RS4GC handles relocation across
  the alloc safepoint). Unifies all aggregate kinds on the
  Record/Custom pattern and removes `widenFieldToI64` from the alloc-
  arg pipeline entirely. Touches `eco.to_heap` and `eco.construct.*`
  lowerings for Tuple2/Tuple3/Cons, plus the runtime ABI in
  `eco-kernel-cpp` and the `EcoRuntime` MLIR declarations.
- **Fix A (wrapper-side).** In `replaceBodyWithWrapper`, replace the
  `eco.make.* + eco.to_heap` pair with a single `eco.construct.*` op,
  for **both** Sret and Direct result branches. The aggregate FCA is
  never built. Localised to the wrapper. Relies on Fix C for GC
  correctness on mixed-element Tuple2/Tuple3 shapes.

## 1. Background — what's actually broken

### 1.0. The fundamental RS4GC limitation

`RewriteStatepointsForGC.cpp:3212`'s `computeLiveInValues` asserts
`!isUnhandledGCPointerType(V->getType(), GC)` with message
`"support for FCA unimplemented"` whenever it has to track a
first-class aggregate (LLVM `struct`/`array`) **whose element type
includes a GC pointer (`ptr addrspace(1)`)** across a safepoint. The
assertion fires regardless of how the FCA was produced
(`insertvalue` chain, multi-result call return, function-exit
return) and regardless of pipeline (`ecoc --emit=jit`,
`ecoc --emit=llvm`, `eco-boot-native --emit=llvm` all reach RS4GC).
Anything that gets folded away before RS4GC sees it is fine; anything
that survives — even one extractvalue whose insertvalue source isn't
directly reachable — asserts.

Two independent IR shapes trigger this in the cross-spec pipeline:

**Shape A — transient FCA around the alloc safepoint.** The wrapper
or Record/Custom `eco.to_heap` lowering builds an `insertvalue` chain
to package fields, then alloc-then-extract-from-FCA to store them in
the new heap object. The FCA is live across the alloc safepoint. If
`FoldExtractValuePass` can fold every extract back through its
matching insert, the FCA becomes dead and is DCE'd; otherwise it
survives and asserts. Subject of Fix B (Record/Custom reorder) and
Fix C (Tuple2/Tuple3/Cons alloc-uninit + per-field stores).

**Shape B — multi-result `func.func` with ≥1 `!eco.value` element.**
FuncToLLVM packs multi-results into a single `!llvm.struct<(...)>`
return type. If any field is `ptr addrspace(1)`, the function's
`llvm.return` is an FCA-of-GC-ptr crossing the function-exit
safepoint. No fold pass can remove this — the FCA IS the function's
ABI interface. Cross-spec produces this shape whenever it routes an
aggregate result through the Direct ABI and the aggregate contains
`!eco.value` elements. Today the all-primitive gate at
`EcoUnboxedAggCrossSpec.cpp:585-590` / `:697-712` prevents this from
happening for Elm-generated `eco.return` bodies. Without addressing
Shape B, lifting the gate (Chunk 4) re-triggers the assertion. The
Sret ABI (Phase 3.3) inherently avoids Shape B because the
worker's LLVM signature is `void @f$unboxed(ptr %sret, ...)` — no
struct return at all. The sret slot's *pointee* type is an
`!llvm.struct<>` whose layout may include `ptr addrspace(1)` element
slots (it's the in-memory representation of the result aggregate),
but the slot pointer is `ptrTy` in addrspace 0 (`LLVM::AllocaOp` at
`replaceBodyWithWrapper:1468`), and the worker writes / wrapper
reads fields via per-element GEP + store/load. No
`!llvm.struct<(... ptr<1> ...)>` value ever sits in a register, so
RS4GC tracks each `ptr<1>` field individually — exactly the case it
handles natively.

### 1.0.1. Minimal-trigger sweep (2026-05-20)

A sweep of five hand-rolled MLIR fixtures pinned the trigger
condition for Shape B precisely. Each is a tiny module containing
one `func.func @worker` plus a `func.func @main` that calls it; only
the worker's signature differs across fixtures. Run through
`ecoc --emit=jit`:

| # | worker signature | crash? |
|---|---|---|
| 01 | `(!eco.value, !eco.value) -> !eco.value`, body uses `eco.construct.tuple2 → return` (single result) | no |
| 02 | `(!eco.value, !eco.value) -> (!eco.value, !eco.value)` (multi-result, both boxed) | **yes** |
| 03 | `(!eco.value, !eco.value) -> !eco.value` (single-result) | no |
| 04 | `(i64, i64) -> (i64, i64)` (multi-result, no GC ptrs) | no |
| 05 | `(i64, !eco.value) -> (i64, !eco.value)` (multi-result, one boxed) | **yes** |

The trigger condition is sharper than "FCA over GC pointers" alone:
specifically, **a `func.func` whose result count is greater than one
AND whose lowered LLVM struct-return type contains at least one
`ptr addrspace(1)` element**. Single-result boxed (#03) is fine —
the function returns `ptr<1>` directly with no struct involved.
Multi-result of pure primitives (#04) is fine — the struct contains
no GC pointers. The "multi-result" axis matters because that's what
makes FuncToLLVM produce an `!llvm.struct<>` return type at all.

#02 and #05 are exactly what cross-spec emits today when it routes
an aggregate result through the Direct ABI and the aggregate carries
`!eco.value` element(s) — which is precisely what the all-primitive
gate (`EcoUnboxedAggCrossSpec.cpp:585-590` and `:697-712`) prevents
from being emitted for `eco.return` bodies, and what Chunk 4 must
NOT cause to be emitted when it lifts the gate. Re-route through
Sret (Phase 3.3) instead; the Sret worker signature is `void
@f$unboxed(ptr %sret, ...)`, single-result void, which can never
trip Shape B.

The lowered MLIR LLVM dialect for fixture #02 — the canonical Shape
B repro:

```mlir
llvm.func @worker(%arg0: !llvm.ptr<1>, %arg1: !llvm.ptr<1>)
    -> !llvm.struct<(ptr<1>, ptr<1>)>
    attributes {garbageCollector = "eco-gc"} {
  %0 = llvm.mlir.poison : !llvm.struct<(ptr<1>, ptr<1>)>
  %1 = llvm.insertvalue %arg0, %0[0] : !llvm.struct<(ptr<1>, ptr<1>)>
  %2 = llvm.insertvalue %arg1, %1[1] : !llvm.struct<(ptr<1>, ptr<1>)>
  llvm.return %2 : !llvm.struct<(ptr<1>, ptr<1>)>
}
```

`%2`'s type is the FCA-of-GC-ptr. `llvm.return %2` is the
function-exit safepoint. RS4GC's `computeLiveInValues` walks back
from this return looking for live `ptr<1>` values, finds `%2`, calls
`isUnhandledGCPointerType` on its struct type, sees a GC pointer
field, asserts.

### 1.1. Pre-existing per-shape diagnosis

Recap of the failure mode (full diagnosis in conversation log; summary
here):

- The wrapper's Sret branch loads fields out of the sret slot as
  `ptr addrspace(1)` scalars, builds an Eco-dialect aggregate via
  `eco.make.tuple2/3/record/custom(loadedFields)`, then calls
  `eco.to_heap` on the aggregate.
- After `EcoToLLVM`:
  - `eco.make.*` lowers to an `insertvalue` chain (`buildStruct` in
    `EcoToLLVMValueAgg.cpp:46-54`).
  - `eco.to_heap` lowers in **two different orderings** depending on
    the aggregate kind:
    - **Tuple2/Tuple3/Cons:** all `extractvalue` first, then
      `widenFieldToI64` (which is `ptrtoint` for `ptr addrspace(1)`)
      on every operand, then `emitAllocWithSafepoint(eco_alloc_tupleN,
      scalars)`. No FCA lives across the alloc safepoint. ✅ for FCA.
      **But:** for `!eco.value` fields the pre-alloc `ptrtoint` strips
      gc-pointer status before the safepoint, so RS4GC doesn't relocate
      the pointer; if GC moves the underlying object during the alloc,
      the i64 is stale and gets stored into the new tuple's slot. ❌
      for GC correctness. This is a pre-existing latent bug; Fix C
      addresses it.
    - **Record/Custom:** `emitAllocWithSafepoint(eco_alloc_record/custom, …)`
      **first**, then a loop over fields with `extractvalue %agg, k` +
      `call eco_store_record_field(%obj, k, %f_k)`. The FCA `%agg` is
      live across the alloc safepoint until every extract is folded
      away. ❌ for FCA. ✅ for GC (boxed fields are stored as
      `ptr addrspace(1)` post-alloc — no ptrtoint).
- `addEcoGCPipeline` (`EcoPtrIntVerify.cpp:412-440`) runs
  `mem2reg + SROA + FoldExtractValuePass` before `RewriteStatepointsForGC`.
  `FoldExtractValuePass` (`:355-408`) walks back through `InsertValueInst`
  only; any non-insertvalue op in the chain (e.g. `select`, `phi`,
  unreconciled cast) breaks the walk and the extract isn't folded. Even
  one unfolded extract keeps the FCA alive, which RS4GC then asserts on.

The "some Elm shapes" wording in the gate's source comment reflects
that the failure is shape-dependent: simple hand-written `func.return`
fixtures (Tuple2/Tuple3 today) fold cleanly; real Elm bodies returning
records or customs occasionally don't. The Phase 3.4 #1 gate punts the
problem by demoting every non-all-primitive `eco.return` aggregate to
Boxed.

## 2. Why the wrapper boxes at all — sanity check

Cross-spec produces two functions per eligible symbol:

```
caller ─┬─→ @foo            (wrapper; preserves original boxed ABI for
        │                    PAP/indirect/foreign/unrewriteable callers)
        │                    └─ eco.from_heap params → call @foo$unboxed
        │                       → eco.construct.*    (re-box result)
        │
        └─→ @foo$unboxed    (worker; scalar params, Direct or Sret result;
                             body never boxes the result)
```

Cross-spec-aware **direct call sites** inside other eligible functions
are rewritten to target `@foo$unboxed`, with `eco.from_heap` /
`eco.to_heap` bridges that the surrounding fixpoint folds away when the
surrounding function is also promoted. On that fast path the aggregate
result never touches the heap.

The wrapper exists only for callers cross-spec can't rewrite —
PAP-mediated calls, indirect/foreign callers, polymorphic call sites
that don't statically resolve. Those callers expect the original boxed
ABI, so the wrapper boxes the worker's unboxed result. **The
optimization win lives on the rewritten direct call sites, not in the
wrapper.** The wrapper's heap allocation cost is the same as the
unoptimized original code's; lifting the gate doesn't regress the slow
path, it just enables the fast path for more shapes.

## 3. Out of scope

- The `eco.case` recursion in `isAcceptedAggregateProducer`
  (`EcoUnboxedAggCrossSpec.cpp:530-538`). That gate exists for a
  separate reason (a Stage 7 self-compile OOB in `retypeJoinTree`'s
  `eco.case` rebuild, not yet repro'd in a small fixture). Stays
  disabled by this plan.
- Phase 3.4 #2 (`eco.joinpoint` loop-carry). Independent deferral.
- `from_heap`-side parallels. `eco.from_heap` for records/customs builds
  the aggregate from heap loads, not from a slot — its lowering pattern
  is distinct and not the subject of this plan.

## 4. Implementation

The implementation is one pass through the tree. Five conceptual chunks
(roughly logical commits, though the work is contiguous):

### Chunk 1 — Fix B: reorder Record/Custom `ToHeapOpLowering`

**File:** `runtime/src/codegen/Passes/EcoToLLVMValueAgg.cpp`

**Record branch (`:271-316`).** Today:

```cpp
// alloc first (safepoint!) — FCA %agg is live across this call
Value objHPtr = emitAllocWithSafepoint(/*record alloc*/, …);
// per-field: extract from agg, maybe widen, store to obj
for (i = 0; i < fieldCount; ++i) {
    Value fieldVal = extractField(rewriter, loc, agg, i, llvmElt);
    /* type-conditional widen + store, see :298-313 */
}
```

After Fix B:

```cpp
// 1. Pre-extract every field as a scalar SSA value (no widening,
//    no store — just decompose the FCA).
SmallVector<Value, 8> extracted;
extracted.reserve(fieldCount);
for (i = 0; i < fieldCount; ++i) {
    Type llvmElt = getTypeConverter()->convertType(fields[i]);
    extracted.push_back(extractField(rewriter, loc, agg, i, llvmElt));
}

// 2. Alloc the heap object. Only scalars from step 1 are live across
//    the safepoint; the FCA is dead after FoldExtractValuePass folds
//    the extracts back through the insertvalue chain.
Value objHPtr = emitAllocWithSafepoint(/*record alloc*/, …);

// 3. Per-field: widen (post-alloc!) + store. Identical logic to today,
//    but the input is `extracted[i]` instead of a fresh extract.
//    Widening stays here because:
//      - i1/i16 zext: semantically free either side of the safepoint,
//        but post-alloc keeps a single canonical position.
//      - ptr addrspace(1): the Record path doesn't widen pointers
//        (it passes them directly to storeFunc), so no ordering
//        concern arises here.
for (i = 0; i < fieldCount; ++i) {
    auto idx = … ConstantOp i32 …;
    Type origTy = fields[i];
    Value v = extracted[i];
    if (origTy.isF64()) {
        rewriter.create<LLVM::CallOp>(storeF64Func, {objHPtr, idx, v});
    } else if (origTy.isInteger(64)) {
        rewriter.create<LLVM::CallOp>(storeI64Func, {objHPtr, idx, v});
    } else if (origTy.isInteger(1) || origTy.isInteger(16)) {
        Value widened = widenFieldToI64Local(v, loc, rewriter);
        rewriter.create<LLVM::CallOp>(storeI64Func, {objHPtr, idx, widened});
    } else {
        rewriter.create<LLVM::CallOp>(storeFunc, {objHPtr, idx, v});
    }
}
```

**Custom branch (`:318-371`).** Same restructuring: pre-extract all
fields, then alloc, then per-field widen-and-store. The existing
`setUnboxed` call stays where it is (after the store loop).

**No change to Tuple2/Tuple3/Cons.** Their existing order already
matches the target shape (extracts before alloc).

**Why this works.** Pre-extracting all fields means every consumer of
the FCA is a sequence of `extractvalue` ops *before* the alloc
safepoint. `FoldExtractValuePass` folds each extract to the matching
inserted value (the loaded slot field, in the wrapper case; the
constructed field in any other caller). With every extract folded, the
FCA chain is trivially dead and gets removed by
`RecursivelyDeleteTriviallyDeadInstructions`. After cleanup, only
`ptr addrspace(1)` scalars cross the alloc safepoint — exactly the
shape RS4GC handles natively.

### Chunk 2 — Fix C: decouple alloc from field store for Tuple2/Tuple3/Cons

This is the most invasive chunk, touching both the runtime ABI
(`eco-kernel-cpp` + `EcoRuntime` MLIR declarations) and the
`eco.to_heap` + `eco.construct.*` lowerings for Tuple2/Tuple3/Cons.
The goal is to unify all aggregate kinds on the Record/Custom pattern:
**alloc takes only structural args (count/bitmap/kind); field values
are written via post-alloc store helpers that take the field's natural
type (`ptr addrspace(1)` for boxed, `i64`/`f64` for primitives).** This
removes `widenFieldToI64` from the alloc-arg pipeline and lets RS4GC
relocate `ptr addrspace(1)` field values across the alloc safepoint
the standard way.

#### Chunk 2.1 — Runtime ABI additions

**Files:**
- `eco-kernel-cpp/src/*` — implementation
- `runtime/src/codegen/EcoRuntime.{h,cpp}` — MLIR-level declarations

**New runtime entries:**

| Symbol | Args | Returns | Notes |
|---|---|---|---|
| `eco_alloc_tuple2_uninit` | `i32 unboxed_bitmap` | `ptr addrspace(1)` | Allocates a Tuple2 heap object with the given bitmap; field slots start zeroed. The bitmap is set up-front so GC can scan safely if a collection fires between alloc and the field stores. |
| `eco_alloc_tuple3_uninit` | `i32 unboxed_bitmap` | `ptr addrspace(1)` | Tuple3 analog. |
| `eco_alloc_cons_uninit` | `i32 head_kind` | `ptr addrspace(1)` | Cons analog. `head_kind` (0/1/2/3 per existing encoding) is set up-front so GC can scan the head slot correctly; head and tail slots start zeroed. |
| `eco_store_tuple_field` | `ptr addrspace(1) tuple, i32 idx, ptr addrspace(1) val` | void | Writes a boxed (`!eco.value`) field. |
| `eco_store_tuple_field_i64` | `ptr addrspace(1) tuple, i32 idx, i64 val` | void | Writes an i64 / Bool-widened / Char-widened field. |
| `eco_store_tuple_field_f64` | `ptr addrspace(1) tuple, i32 idx, f64 val` | void | Writes an f64 field. |
| `eco_store_cons_head` | `ptr addrspace(1) cons, ptr addrspace(1) val` | void | Writes the cons head when boxed (`head_kind == 0`). |
| `eco_store_cons_head_i64` | `ptr addrspace(1) cons, i64 val` | void | Writes the head when `head_kind` is Int/Bool/Char (widened to i64). |
| `eco_store_cons_head_f64` | `ptr addrspace(1) cons, f64 val` | void | Writes the head when `head_kind` is Float. |
| `eco_store_cons_tail` | `ptr addrspace(1) cons, ptr addrspace(1) val` | void | Writes the cons tail (always boxed; tail is the next cons cell or nil). |

The tuple store helpers can be **shared** between Tuple2 and Tuple3
since they take the tuple pointer + index — the runtime can identify
the layout from the header. (Same pattern as `eco_store_record_field`
serves arbitrary-arity records.) If the existing tuple-vs-record
header layouts differ enough that sharing isn't sound, fall back to
separate `tuple2`/`tuple3`-specific helpers — confirm during
implementation; doesn't change the lowering shape.

**Whether store helpers are safepoints.** Implementation choice in
`eco-kernel-cpp`: mark the store helpers gc-leaf if they don't
allocate. The lowering tolerates either (RS4GC tracks live
`ptr addrspace(1)` values across multiple safepoints natively) — but
gc-leaf store helpers reduce the number of statepoint records emitted,
which is friendlier to the compiler and runtime. Default to gc-leaf
unless an implementation reason forces a safepoint.

**Old entries removed.** `eco_alloc_tuple2`, `eco_alloc_tuple3`, and
`eco_alloc_cons` (the existing field-taking forms) are removed once
every call site is migrated. They're internal runtime; no external
caller. Removal is a clean delete in the same pass.

#### Chunk 2.2 — `ToHeapOpLowering` (Tuple2/Tuple3/Cons branches)

**File:** `runtime/src/codegen/Passes/EcoToLLVMValueAgg.cpp`

**Tuple2 branch (`:217-241`).** Today:

```cpp
Value a = extractField(rewriter, loc, agg, 0, llvmElts[0]);
Value b = extractField(rewriter, loc, agg, 1, llvmElts[1]);
a = widenFieldToI64Local(a, loc, rewriter);   // ❌ ptrtoint pre-alloc
b = widenFieldToI64Local(b, loc, rewriter);   // ❌ ptrtoint pre-alloc
Value result = emitAllocWithSafepoint(/*eco_alloc_tuple2*/, {a, b, unboxedVal}, …);
```

After Fix C:

```cpp
// 1. Pre-extract the two fields (no widening yet — keep them in their
//    natural LLVM types: ptr addrspace(1) for boxed, i64/f64/i16 for
//    primitives).
Value a = extractField(rewriter, loc, agg, 0, llvmElts[0]);
Value b = extractField(rewriter, loc, agg, 1, llvmElts[1]);

// 2. Alloc uninitialized Tuple2 with bitmap set so GC can scan safely.
Value tuple = emitAllocWithSafepoint(
    op, rewriter, runtime,
    runtime.getOrCreateAllocTuple2Uninit(rewriter),
    ValueRange{unboxedVal},
    liveRoots);

// 3. Per-field, dispatch on origTy and store via the right helper.
//    The `ptr addrspace(1)` path uses storeFunc directly (no ptrtoint);
//    RS4GC has relocated `a`/`b` across the alloc safepoint above.
auto storeBoxedField = [&](unsigned idx, Value v, Type origTy) {
    auto idxVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
        static_cast<int32_t>(idx));
    if (origTy.isF64()) {
        rewriter.create<LLVM::CallOp>(
            loc, runtime.getOrCreateStoreTupleFieldF64(rewriter),
            ValueRange{tuple, idxVal, v});
    } else if (origTy.isInteger(64)) {
        rewriter.create<LLVM::CallOp>(
            loc, runtime.getOrCreateStoreTupleFieldI64(rewriter),
            ValueRange{tuple, idxVal, v});
    } else if (origTy.isInteger(1) || origTy.isInteger(16)) {
        // i1/i16 zext to i64 is Pure — fine pre- or post-alloc, but
        // we do it post-alloc here for consistency with Record/Custom.
        Value widened = widenFieldToI64Local(v, loc, rewriter);
        rewriter.create<LLVM::CallOp>(
            loc, runtime.getOrCreateStoreTupleFieldI64(rewriter),
            ValueRange{tuple, idxVal, widened});
    } else {
        // !eco.value → ptr addrspace(1): pass directly, no ptrtoint.
        rewriter.create<LLVM::CallOp>(
            loc, runtime.getOrCreateStoreTupleField(rewriter),
            ValueRange{tuple, idxVal, v});
    }
};
storeBoxedField(0, a, elts[0]);
storeBoxedField(1, b, elts[1]);
rewriter.replaceOp(op, tuple);
```

**Tuple3 branch (`:244-269`):** analogous, three fields instead of two.

**Cons branch (`:374-410`):**

```cpp
// 1. Pre-extract head and tail.
Value head = extractField(rewriter, loc, agg, 0, llvmHead);  // ptr<1> or i64/f64/i16
Value tail = extractField(rewriter, loc, agg, 1, llvmTail);  // ptr addrspace(1) (tail is always boxed)

// 2. Compute head_kind (same logic as today, lines 381-396) and alloc
//    uninit with kind set.
auto kindVal = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
    static_cast<int32_t>(kind));
Value cons = emitAllocWithSafepoint(
    op, rewriter, runtime,
    runtime.getOrCreateAllocConsUninit(rewriter),
    ValueRange{kindVal}, liveRoots);

// 3. Post-alloc per-field stores.
Type headTy = cons.getHead();   // Eco-dialect element type
if (kind == 0) {
    // Boxed head: pass ptr addrspace(1) directly.
    rewriter.create<LLVM::CallOp>(
        loc, runtime.getOrCreateStoreConsHead(rewriter),
        ValueRange{cons, head});
} else if (headTy.isF64()) {
    rewriter.create<LLVM::CallOp>(
        loc, runtime.getOrCreateStoreConsHeadF64(rewriter),
        ValueRange{cons, head});
} else {
    // i64 / Char (i16) / Bool (i1): widen post-alloc.
    Value widened = widenFieldToI64Local(head, loc, rewriter);
    rewriter.create<LLVM::CallOp>(
        loc, runtime.getOrCreateStoreConsHeadI64(rewriter),
        ValueRange{cons, widened});
}
// Tail is always boxed.
rewriter.create<LLVM::CallOp>(
    loc, runtime.getOrCreateStoreConsTail(rewriter),
    ValueRange{cons, tail});
rewriter.replaceOp(op, cons);
```

**No change to Record/Custom branches** beyond Chunk 1's reordering.

#### Chunk 2.3 — `Tuple2/Tuple3/ConsConstructOpLowering`

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`

Same transformation as Chunk 2.2 but starting from `adaptor.getA()` /
`adaptor.getB()` / `adaptor.getC()` etc. directly (no `extractField`
needed — the operands are already SSA values from the construct op's
operand list).

`Tuple2ConstructOpLowering` (`:479-507`), `Tuple3ConstructOpLowering`
(`:513-542`), and the Cons construct op lowering all change to the
alloc-uninit-then-store pattern. The `widenFieldToI64` calls at
`:493-494` (Tuple2) and `:527-529` (Tuple3) are removed; widening
happens inside the per-field store helper logic as in Chunk 2.2.

#### Chunk 2.4 — Sweep for stragglers

Grep for `getOrCreateAllocTuple2`, `getOrCreateAllocTuple3`,
`getOrCreateAllocCons` in `runtime/src/codegen/` to confirm every
caller is migrated. Expected hits: the lowering files above. Any
unexpected caller (e.g., a wrapper-builder helper elsewhere) gets
migrated in the same pass.

#### Why this works (Tuple2 example with mixed-element shape)

After lowering, the LLVM IR for `eco.to_heap %agg` where
`%agg = make.tuple2 %p0, %p1` and both fields are `!eco.value`:

```
%p0 = … ; ptr addrspace(1)
%p1 = … ; ptr addrspace(1)
%agg = insertvalue insertvalue undef, %p0, 0, %p1, 1     ; FCA, but dead
%p0_e = extractvalue %agg, 0                              ; FoldExtractValuePass folds → %p0
%p1_e = extractvalue %agg, 1                              ; folds → %p1
%tuple = call ptr addrspace(1) @eco_alloc_tuple2_uninit(i32 0)   ; SAFEPOINT
         ; RS4GC relocates %p0, %p1 to %p0', %p1' here
         call void @eco_store_tuple_field(ptr addrspace(1) %tuple, i32 0, ptr addrspace(1) %p0')
         call void @eco_store_tuple_field(ptr addrspace(1) %tuple, i32 1, ptr addrspace(1) %p1')
ret ptr addrspace(1) %tuple
```

Field values cross the alloc safepoint as **`ptr addrspace(1)` scalars**,
which RS4GC handles natively. No `ptrtoint` in the live path. The FCA
is dead after `FoldExtractValuePass` and is removed by `RecursivelyDeleteTriviallyDeadInstructions`.

#### Chunk 2.5 — Verification gate (mandatory before claiming Fix C done)

The 2026-05-20 investigation showed that "build is green at
`-emit=mlir-llvm`" is **not** sufficient evidence — the previous
attempt produced IR that asserted in RS4GC despite looking fine at
the MLIR LLVM-dialect stage. A re-attempt of Chunks 2.2 / 2.3 must
include the following structural check before merging:

```bash
# For every per-test MLIR input that exercises the changed lowering:
ecoc --emit=mlir-llvm <input>.mlir 2>&1 \
    | grep -E '!llvm\.struct<\([^)]*ptr<1>[^)]*\)>'
# Expected output: empty.
```

Any match indicates a survived FCA-of-GC-ptr. The expected hits to
*positively eliminate* in the lowered output are:

- `llvm.func @foo(...) -> !llvm.struct<(ptr<1>, ...)>` —
  multi-result `func.func` returning ≥1 `!eco.value`. Either route
  through Sret (Phase 3.3) or fall back to Boxed; never emit this
  return type.
- `%x = llvm.insertvalue ... : !llvm.struct<(... ptr<1> ...)>` —
  transient FCA construction. Must be dead by the time RS4GC sees
  it; if `FoldExtractValuePass` can't fold the consumers, redesign
  the lowering to not construct the FCA in the first place
  (Fix C's alloc-uninit + per-field stores is the template).
- `%x = llvm.call @bar(...) : (...) -> !llvm.struct<(... ptr<1> ...)>`
  — call result FCA. Same disposition as the return case.
- `%x = llvm.extractvalue %y[k] : !llvm.struct<(... ptr<1> ...)>`
  — survives whenever the matching insertvalue isn't directly
  reachable from %y. Treat as a fold-blocker; trace the chain
  (`select`, `phi`, `bitcast`, `unrealized_conversion_cast`) and
  remove or restructure.

This is the verification step that should have run during the
previous Chunks 2.2 / 2.3 attempt. Including it as a numbered
sub-chunk forces the re-implementer to run it. The §1.0.1 sweep
shapes serve as the regression-sentinel set: shapes #02 and #05
must NOT be emitted by cross-spec after the gate is lifted (Chunk
4 routes them through Sret instead), and the wrapper's lowering
for Record/Custom/Tuple bodies must produce zero
`!llvm.struct<(... ptr<1> ...)>` SSA values in the final IR.

### Chunk 3 — Fix A: wrapper emits `eco.construct.*` directly (both Sret and Direct branches)

**File:** `runtime/src/codegen/Passes/EcoUnboxedAggCrossSpec.cpp`

**Target:** `replaceBodyWithWrapper` (`:1387-1534`). Both the Sret
branch (`:1456-1505`) and the Direct branch (`:1508-1531`) change.

**Sret branch — after Fix A:**

```cpp
SmallVector<Value, 4> loadedFields;
emitSretLoad(builder, loc, sretSlots[sretCursor], sretSlotTys[sretCursor],
             rs.elementTys, loadedFields);
++sretCursor;

Type boxedTy = original.getFunctionType().getResult(i);
uint64_t bitmap = static_cast<uint64_t>(computeUnboxedBitmap(rs.elementTys));

Value boxed;
switch (rs.kind) {
case LogicalShape::Tuple2:
    boxed = builder.create<eco::Tuple2ConstructOp>(
        loc, boxedTy, loadedFields[0], loadedFields[1],
        /*live_roots=*/ValueRange{},
        bitmap);
    break;
case LogicalShape::Tuple3:
    boxed = builder.create<eco::Tuple3ConstructOp>(
        loc, boxedTy, loadedFields[0], loadedFields[1], loadedFields[2],
        /*live_roots=*/ValueRange{},
        bitmap);
    break;
case LogicalShape::Record:
    boxed = builder.create<eco::RecordConstructOp>(
        loc, boxedTy, ValueRange(loadedFields),
        /*field_count=*/static_cast<uint64_t>(loadedFields.size()),
        bitmap);
    break;
case LogicalShape::Custom: {
    uint64_t tag = i < customTagPerResult.size()
                     ? static_cast<uint64_t>(customTagPerResult[i]) : 0;
    boxed = builder.create<eco::CustomConstructOp>(
        loc, boxedTy, ValueRange(loadedFields),
        tag,
        /*size=*/static_cast<uint64_t>(loadedFields.size()),
        bitmap,
        /*constructor=*/StringAttr());
    break;
}
default:
    llvm_unreachable("Sret on non-aggregate shape");
}
returnValues.push_back(boxed);
```

**Direct branch — after Fix A:** the worker returns the aggregate
**by-value** (an LLVM struct in MLIR multi-result form, represented at
the Eco level as `!eco.tuple2<…>` / `!eco.tuple3<…>` / `!eco.record<…>`
/ `!eco.custom<…>`). The wrapper currently does `eco.to_heap` on it;
after Fix A the wrapper projects each field via `eco.project.*` and
feeds the scalars to `eco.construct.*`. Per Q4 (Direct = all-primitive
by `chooseResultAbi`), there's no GC correctness benefit — this change
is purely for uniformity with the Sret branch and to make the wrapper's
shape easy to reason about.

```cpp
// Direct path: the worker returned the aggregate as a value-level
// struct via the LLVM multi-return packing. Project each field then
// rebuild via eco.construct.* — symmetric to the Sret path.
Value v = callOp.getResult(directCursor++);
if (!rs.isAggregate()) {
    returnValues.push_back(v);
    continue;
}

Type boxedTy = original.getFunctionType().getResult(i);
uint64_t bitmap = static_cast<uint64_t>(computeUnboxedBitmap(rs.elementTys));

// Project each field out of the by-value aggregate.
SmallVector<Value, 4> projected;
projected.reserve(rs.elementTys.size());
for (unsigned k = 0; k < rs.elementTys.size(); ++k) {
    Type elemTy = rs.elementTys[k];
    auto idx = builder.getI64IntegerAttr(static_cast<int64_t>(k));
    Value f;
    if (rs.kind == LogicalShape::Tuple2)
        f = builder.create<eco::Tuple2ProjectOp>(loc, elemTy, v, idx);
    else if (rs.kind == LogicalShape::Tuple3)
        f = builder.create<eco::Tuple3ProjectOp>(loc, elemTy, v, idx);
    else if (rs.kind == LogicalShape::Record)
        f = builder.create<eco::RecordProjectOp>(loc, elemTy, v, idx);
    else if (rs.kind == LogicalShape::Custom)
        f = builder.create<eco::CustomProjectOp>(loc, elemTy, v, idx);
    else
        llvm_unreachable("Direct on non-aggregate shape");
    projected.push_back(f);
}

Value boxed;
switch (rs.kind) {
case LogicalShape::Tuple2:
    boxed = builder.create<eco::Tuple2ConstructOp>(
        loc, boxedTy, projected[0], projected[1],
        /*live_roots=*/ValueRange{}, bitmap);
    break;
case LogicalShape::Tuple3:
    boxed = builder.create<eco::Tuple3ConstructOp>(
        loc, boxedTy, projected[0], projected[1], projected[2],
        /*live_roots=*/ValueRange{}, bitmap);
    break;
case LogicalShape::Record:
    boxed = builder.create<eco::RecordConstructOp>(
        loc, boxedTy, ValueRange(projected),
        static_cast<uint64_t>(projected.size()), bitmap);
    break;
case LogicalShape::Custom: {
    uint64_t tag = i < customTagPerResult.size()
                     ? static_cast<uint64_t>(customTagPerResult[i]) : 0;
    boxed = builder.create<eco::CustomConstructOp>(
        loc, boxedTy, ValueRange(projected),
        tag, static_cast<uint64_t>(projected.size()), bitmap,
        /*constructor=*/StringAttr());
    break;
}
default:
    llvm_unreachable("Direct on non-aggregate shape");
}
returnValues.push_back(boxed);
```

The `eco.project.* %v[k]` on a value-level aggregate lowers to
`llvm.extractvalue`. Combined with `eco.construct.*`, this means the
Direct branch lowers identically to the old `eco.to_heap`-on-aggregate
path (extractvalues feed the alloc args) — the FCA still exists as the
worker's return value at the wrapper, but it's consumed by extracts
before any safepoint, so `FoldExtractValuePass` collapses it. No
behaviour change for Direct; just a different MLIR-level shape.

**Resulting LLVM IR for the wrapper's Sret-result branch (Record / Custom
case), after Fix A + Fix B:**

```
%slot   = alloca <{ ptr addrspace(1), …}>             ; addrspace 0
         call @foo$unboxed(%slot, …)                   ; SAFEPOINT (worker call)
%f0     = load ptr addrspace(1), ptr %slot+0
%f1     = load ptr addrspace(1), ptr %slot+8
…
%obj    = call ptr addrspace(1) @eco_alloc_record(…)   ; SAFEPOINT
         call @eco_store_record_field(%obj, 0, %f0)    ; %f1..%fN-1 still live; scalar gc ptrs
         call @eco_store_record_field(%obj, 1, %f1)
…
ret %obj
```

Only `ptr addrspace(1)` **scalars** are live across any safepoint. No
`insertvalue` chain is ever built. RS4GC handles it natively.

### Chunk 4 — Lift the all-primitive gate

**File:** `runtime/src/codegen/Passes/EcoUnboxedAggCrossSpec.cpp`

After Chunks 1–3 land, remove the two gates that were tracking the
FCA blocker:

- `:563-575` in `resultPositionHasAggregateProducer`'s `eco.return`
  branch — delete the `allPrim` check; `checkOperand` walks `eco.return`
  the same way it walks `func.return`.
- `:686-694` in `allUsesAreProjectionsOrCallsToEligible`'s `eco.return`
  passthrough branch — delete the symmetric `allPrim` check inside the
  `isa<eco::ReturnOp>` arm.

Both gates are bracketed by comments referring to "the FCA/RS4GC sret
limitation". The comments come out with the gates.

### Chunk 5 — Fixtures

Style — match `test/codegen/cross_spec_join_select_tuple.mlir`:
- `// RUN: %ecoc %s -emit=mlir-llvm -enable-unboxed-agg 2>&1 | %FileCheck %s`
- Comment header narrating the test's purpose and what would have failed pre-fix.
- `CHECK-DAG` for the worker/wrapper pair existence.
- `CHECK-NOT` for absent ops (e.g. no `eco.construct.tuple2` remains in the worker).

New fixtures:

1. **`test/codegen/to_heap_record_no_fca.mlir`** — direct
   `eco.make.record(<!eco.value, !eco.value>) → eco.to_heap` chain;
   FileCheck asserts no `insertvalue` lingers between the make and the
   alloc, and no FCA-typed value spans `eco_alloc_record`. Verifies
   Fix B independently of cross-spec.
2. **`test/codegen/to_heap_custom_no_fca.mlir`** — same shape for
   Custom.
3. **`test/codegen/to_heap_tuple2_boxed_field_no_ptrtoint.mlir`** —
   direct `eco.make.tuple2(<!eco.value, !eco.value>) → eco.to_heap`
   chain; FileCheck asserts the lowered IR uses
   `eco_alloc_tuple2_uninit` + `eco_store_tuple_field` and **does
   not** contain `llvm.ptrtoint` in the field-store path. Verifies
   Fix C for Tuple2.
4. **`test/codegen/to_heap_cons_boxed_head_no_ptrtoint.mlir`** —
   analogous for Cons-with-boxed-head, asserting
   `eco_alloc_cons_uninit` + `eco_store_cons_head` and no `ptrtoint`.
5. **`test/codegen/cross_spec_sret_record_construct.mlir`** — an Elm-
   shape MLIR input with `eco.return` of a record containing `!eco.value`
   elements and matching `eco.logical_result_types`. FileCheck verifies
   the wrapper contains `eco.construct.record` (not `eco.make.record + eco.to_heap`)
   and the worker is sret-promoted (leading `!llvm.ptr` outparam).
6. **`test/codegen/cross_spec_sret_mixed_tuple2_construct.mlir`** —
   same shape for a mixed-element Tuple2 (`tuple2:i:H` or `tuple2:H:H`).
   FileCheck verifies the wrapper uses `eco.construct.tuple2` and that
   the lowered LLVM IR uses `eco_alloc_tuple2_uninit` + store helpers.
7. **`test/elm/src/CrossSpecSretMixedRecordTest.elm`** — end-to-end Elm
   test that returns a 2-tuple `(Int, String)` (mixed `i64` + `!eco.value`)
   from a function. Verifies the optimised binary runs correctly and
   the worker is sret-promoted.

### Chunk 6 — Invariant text updates

**File:** `design_docs/invariants.csv`

- **CGEN_064** Phase 3.3 wording: change
  `> rebuild the aggregate via eco.make.* before re-boxing through eco.to_heap`
  to
  `> rebuild and re-box the aggregate via a single eco.construct.* op (the wrapper feeds the loaded sret-slot fields directly as construct operands; no intermediate eco.make.* / eco.to_heap pair is built, so no register-form FCA exists in the wrapper)`.
- **CGEN_064** Phase 3.4 #1 wording: delete the sentence beginning
  `> Sret combined with eco.return on aggregates carrying !eco.value elements is gated for now …` and the trailing "the gate exists because …" justification. Mention the wrapper-side `eco.construct.*` form and the Record/Custom `to_heap` reordering as the resolution.
- **CGEN_067** wording: amend
  `> tracked through any subsequent statepoint (typically eco.to_heap)`
  to
  `> tracked through any subsequent statepoint (typically eco.construct.* in the wrapper's re-box step, or eco.to_heap elsewhere)`.
- **REP_AGG_001**: no change required.

## 5. Verification

1. **`cmake --build build --target full`** (the full E2E suite) — must
   be green. This is the mandatory gate.
2. **Stage 7 self-compile** per `guides/bootstrap.md` (Stages 1–7). The
   native self-compile is the most demanding shape stress test in tree;
   a successful Stage 7 with the gate removed is strong evidence the
   new promotion path is structurally sound. Stage 8 (binary fixed
   point) is a bonus check, not mandatory.

## 6. Effort estimate

| Chunk | LOC est. | Risk |
|---|---|---|
| 1 — Fix B | ~50 cpp | Low. Pure ordering change inside Record/Custom branches; widenings stay where they are. |
| 2 — Fix C | ~200 cpp + ~150 C++ runtime + ~50 EcoRuntime decls | Medium. Touches runtime ABI (new `_uninit` allocators and store helpers in `eco-kernel-cpp`), MLIR runtime declarations, and two lowering files. Risk concentrated in two areas: (a) sharing tuple store helpers across Tuple2/Tuple3 if header layouts permit (verify during impl); (b) ensuring the `_uninit` allocators leave field slots in a state that's safe for GC scan if a collection fires between alloc and field store (zero-init + bitmap/kind set up-front handles this). |
| 3 — Fix A | ~80 cpp | Low–medium. ~1-for-1 op substitution + per-field projection on Direct path; only risk is mistyped builder calls (resolved via Q1 cross-check against generated headers). Depends on Chunk 2 for GC correctness on mixed-element Tuple2/Tuple3 shapes. |
| 4 — Lift gate | ~15 cpp deleted | Low if Chunks 1–3 land clean. |
| 5 — Fixtures | ~220 fixture lines across 7 files | Low. Mostly mechanical FileCheck assertions. |
| 6 — Invariants | ~6 sentence edits | Trivial. |

Total: ~330 LOC compiler C++ + ~150 LOC runtime C++ + ~50 LOC MLIR runtime declarations + ~220 LOC fixtures.

## 7. Out of scope follow-ups

### 7.1 `eco.case` recursion in `isAcceptedAggregateProducer`

Currently disabled at `EcoUnboxedAggCrossSpec.cpp:530-538` due to a
Stage 7 self-compile OOB in `retypeJoinTree`'s `eco.case` rebuild.
Needs a small-fixture repro before re-enabling. Independent issue.

### 7.2 Phase 3.4 #2 `eco.joinpoint` loop-carry

Already deferred per the original Phase 3.4 plan. Independent.

### 7.3 Strengthen `FoldExtractValuePass`

Extend `traceMatchingInsert` to walk through additional ops
(`unrealized_conversion_cast`, `bitcast`, `select`/`phi`). Belt-and-
suspenders — only valuable once there's a repro that names a specific
blocking op pattern. Don't speculate; revisit if a future shape trips
the fold pass after this plan lands.

## 8. Status (2026-05-20)

### Landed

- **Chunk 2.1 — Runtime ABI additions.**
  - `eco-kernel-cpp` / `runtime/src/allocator/RuntimeExports.{h,cpp}`:
    `eco_alloc_tuple2_uninit`, `eco_alloc_tuple3_uninit`,
    `eco_alloc_cons_uninit`, `eco_store_tuple_field{,_i64,_f64}`,
    `eco_store_cons_head{,_i64,_f64}`, `eco_store_cons_tail`.
    All allocators zero-initialise the body and set the header
    bitmap/kind so a mid-store GC scan finds null pointers in
    HPointer-kind slots rather than uninitialised garbage.
  - `runtime/src/codegen/RuntimeSymbols.cpp`: JIT symbol map entries
    for all ten new entries.
  - `runtime/src/codegen/Passes/EcoToLLVMInternal.h` +
    `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp`: matching
    `getOrCreate*` declarations and definitions.
  - The full E2E test suite passes at the same rate as the
    pre-change baseline (1413/1414; the lone failure
    `MVarReadDoesNotEmptyTest` is pre-existing and reproducible
    with all my changes reverted — it crashes inside LLVM
    `StatepointLowering` with the `CallEnd != CALLSEQ_END` assertion
    independent of any work here; see `plans/wide-direct-abi-statepoint-fix.md`).

- **Doc clean-up (2026-05-20).** `EcoUnboxedAggCrossSpec.cpp:1422-1436`
  had a stale doc comment from the reverted Chunk 3 attempt that
  described the wrapper as emitting `eco.construct.*` directly.
  Replaced with an accurate description of the current
  `eco.make.* + eco.to_heap` shape plus a forward pointer to Fix A as
  the deferred change. No code-behavior impact.

- **Diagnosis sweep (2026-05-20).** A hand-rolled MLIR sweep
  (documented in §1.0.1) isolated the RS4GC FCA assertion to its
  minimum trigger condition: a multi-result `func.func` whose
  lowered `!llvm.struct<>` return contains at least one
  `ptr addrspace(1)` field. The fixtures were not retained in tree;
  the trigger condition and lowered IR sample in §1.0.1 are
  sufficient to regenerate them on demand. Chunk 2.5's grep gate is
  the runtime check that any future re-land of Chunks 2/3/4 must
  pass.

### Deferred

- **Chunk 1 — Fix B (Record/Custom `ToHeapOpLowering` reorder).**
  Reverted. The reorder itself is structurally sound — the rebuilt IR
  passes `ecoc -emit=llvm` (which runs `addEcoGCPipeline` end-to-end)
  — but the suite-wide failures co-arrived with Chunks 2.2 / 2.3 / 3,
  so isolating Chunk 1's safety required more bisection than the
  initial pass had time for. Re-enable should be straightforward
  alongside the Chunk 2 work.
- **Chunk 2.2 — `ToHeapOpLowering` Tuple2/Tuple3/Cons branches
  switched to alloc-uninit + per-field store.** Reverted. The
  original status banner attributed the failures to JIT-only
  `packFunctionArguments` interaction; the 2026-05-20 reproducer
  sweep refutes that — the FCA assertion is not JIT-specific (see
  §1.0). The actual cause was almost certainly a transient
  FCA-of-GC-ptr value (Shape A in §1.0) surviving
  `FoldExtractValuePass` along some code path the previous attempt
  didn't audit. Re-attempt with Chunk 2.5's grep gate run against
  the lowered MLIR for every affected fixture to catch any
  surviving FCA before claiming the chunk is green.
- **Chunk 2.3 — `Tuple2/3/ConsConstructOp` lowering switched to
  alloc-uninit + per-field store.** Reverted alongside Chunk 2.2;
  same disposition.
- **Chunk 3 — Wrapper emits `eco.construct.*` directly (Fix A).**
  Reverted. Independent of the lowering-side FCA issue but kept
  disabled until the wider rework lands because the wrapper-side
  reroute calls into `eco.construct.tuple2` etc., which are
  themselves the targets of Chunk 2.3.
- **Chunk 4 — Lift the all-primitive `eco.return` gate.** Reverted.
  With Chunks 1–3 disabled, the gate remains the only mechanism
  preventing mixed-element aggregate returns from materialising
  Shape A (transient FCA around the wrapper's alloc) or Shape B
  (multi-result function signature with `ptr<1>` fields). Cannot
  re-enable until Chunks 1, 2.2, 2.3, 3 are clean against Chunk 2.5.
- **Chunk 5 — New fixtures.** Not landed. The §1.0.1 sweep settled
  the diagnostic question without needing fixtures in tree; Chunk
  5's lit-style FileCheck fixtures from §4 of this plan are still
  pending and would be added alongside the Chunks 1–4 re-land.
- **Chunk 6 — Invariant text updates.** Not landed (CGEN_064 /
  CGEN_067 carve-outs remain in `design_docs/invariants.csv`).

### Next steps for re-enable

The previous "next steps" list focused on bisecting a JIT-only
divergence that doesn't exist. The corrected re-land sequence is:

1. **Re-apply Chunks 1 and 2.2/2.3 + 2.4 (Fix B and Fix C lowering
   changes).** Don't change the runtime ABI — Chunk 2.1 is already
   landed and correct. The work is purely in
   `EcoToLLVMValueAgg.cpp` (Fix B reorder for Record/Custom) and
   `EcoToLLVMHeap.cpp` + `EcoToLLVMValueAgg.cpp`
   (Fix C alloc-uninit + per-field stores for Tuple2/Tuple3/Cons).

2. **Run Chunk 2.5 (grep gate) against every codegen fixture in
   `test/codegen/`.** The existing in-tree fixtures
   (e.g. `specialize_tuple2_boxed.mlir`) must produce zero FCA-of-
   GC-ptr matches after Fix B + Fix C lower the wrapper's transient
   FCA correctly. Optionally regenerate the §1.0.1 sweep ad hoc to
   confirm the trigger condition still holds (#02 and #05 must still
   crash today, since they exercise Shape B, which only Chunk 4 + Sret
   routing can resolve).

3. **Run the full E2E suite.** Confirm all 1413 baseline tests stay
   green and the three previously-failing tests
   (`ProcessSpawnRecursiveTest`, `ProcessYieldThrashingTest`,
   `TaskOnErrorCascadeTest`) now pass.

4. **Re-apply Chunk 3 (Fix A, wrapper `eco.construct.*`).** This step
   is what actually closes the loop on Shape A in the wrapper's
   re-box. After this lands, every Sret-ABI wrapper for a
   boxed-element aggregate result emits zero FCA-of-GC-ptr SSA
   values.

5. **Re-apply Chunk 4 (lift the all-primitive `eco.return` gate)
   and re-run the grep gate against fixtures 02 and 05.** The
   crucial assertion: with Sret ABI now reachable for boxed-element
   results, the workers cross-spec emits should be `void
   @foo$unboxed(ptr %sret, ...)` (Sret) — never multi-result
   `(!eco.value, !eco.value)`. If any Shape B return type survives,
   either `chooseResultAbi` is mis-routing or `buildWorkerType` is
   leaving multi-result for a boxed aggregate; fix that before
   merging.

6. **Re-apply Chunks 5 and 6.** Fixtures + invariant text. Mechanical.

### Why this plan separates Shape A and Shape B

The previous attempt conflated them. Shape A is the wrapper's
internal lowering FCA, fixable by reordering or by alloc-uninit +
per-field stores — that's what Chunks 1–3 + Fix A/B/C do. Shape B
is the worker's interface FCA (multi-result return with GC ptrs);
the only fix is to not emit that signature at all, which is what
the Sret ABI from Phase 3.3 inherently does. Lifting the gate
(Chunk 4) requires both fixes to be in place:

- Chunks 1–3 land → Shape A gone → wrapper compiles cleanly.
- Chunk 4 lands → gate lifted → cross-spec routes boxed aggregates
  through Sret → no Shape B emitted.

If Chunks 1–3 are skipped, Chunk 4 might still produce Shape A in
the wrapper's `eco.make.* + eco.to_heap` re-box → assertion. If
Chunk 4 is landed with no Sret routing for boxed aggregates, the
workers emit Shape B directly → assertion. Both halves are
required.

### Pre-existing failure to be aware of

`MVarReadDoesNotEmptyTest` fails reproducibly even with every change
from this plan reverted. The failure mode is the LLVM
`StatepointLowering` assertion
`CallEnd->getOpcode() == ISD::CALLSEQ_END && "expected!"`. Not in
scope for this plan; flagged here so the next implementer doesn't
chase it as a regression of this work. See
`plans/wide-direct-abi-statepoint-fix.md` for that bug's diagnosis
and proposed fix; it's a separate SelectionDAG-layer issue affecting
wide all-primitive Direct returns, not the FCA-of-GC-ptr issue this
plan addresses.

## 9. Composition with earlier phases

- **Phase 3.3 (sret ABI):** Fix A refines the wrapper code Phase 3.3
  introduced; the sret slot allocation, worker call, and load steps
  are unchanged. Only the re-box step changes.
- **Phase 3.4 #1 (join-shape result producers):** Lifting the gate
  makes the existing `arith.select`-arm promotion path work for
  `eco.return`-terminated Elm functions with mixed-element aggregates.
  No further change to `isAcceptedAggregateProducer` is needed by this
  plan.
- **Phase 3.4 #1 `eco.case` gate:** Untouched. Stage 7 OOB in
  `retypeJoinTree`'s `eco.case` rebuild is a separate issue with no
  known repro.
- **Phase 3.4 #2 (joinpoint loop-carry):** Untouched.
- **EcoFlattenAggBoundary:** Untouched. Operates on function
  boundaries, not on the wrapper's intra-body construct/to_heap chain.
