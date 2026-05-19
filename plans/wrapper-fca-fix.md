# Wrapper FCA Fix — Plan

> **Implementation status (2026-05-19).** Chunk 2.1 (runtime ABI
> additions + JIT symbol registration + MLIR runtime declarations) is
> **landed and verified**: build is green and the full E2E suite has
> the same pass/fail count as the pre-change baseline (1413 passing).
> Chunks 1, 2.2, 2.3, 3, 4, 5, 6 are **deferred** — the initial attempt
> introduced three new test failures
> (`ProcessSpawnRecursiveTest`, `ProcessYieldThrashingTest`,
> `TaskOnErrorCascadeTest`) with the `support for FCA unimplemented`
> assertion firing inside the JIT pipeline (EcoRunner / EcoJIT). The
> failure reproduces deterministically and only inside the JIT —
> `ecoc -emit=llvm` runs `addEcoGCPipeline` on the same MLIR input
> successfully. The difference is `packFunctionArguments` (run by
> EcoJIT, not by ecoc); investigation pointer for the re-enable
> attempt is the interaction between that wrapper-emission and
> alloc-uninit + per-field-store call sequences on functions with
> `gc "eco-gc"`. The Phase 3.4 all-primitive gate stays in place.
> See §9 "Status" at the end for the precise state and next steps.


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

## 8. Status (2026-05-19)

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
    independent of any work here).

### Deferred

- **Chunk 1 — Fix B (Record/Custom `ToHeapOpLowering` reorder).**
  Reverted. The reorder itself is structurally sound — the rebuilt IR
  passes `ecoc -emit=llvm` (which runs `addEcoGCPipeline` end-to-end)
  — but the suite-wide failures co-arrived with Chunks 2.2 / 2.3 / 3,
  so isolating Chunk 1's safety required more bisection than the
  initial pass had time for. Re-enable should be straightforward once
  the underlying JIT-vs-ecoc-divergence in Chunks 2.2 / 2.3 is
  understood.
- **Chunk 2.2 — `ToHeapOpLowering` Tuple2/Tuple3/Cons branches
  switched to alloc-uninit + per-field store.** Reverted. The
  generated LLVM IR is well-formed and ecoc processes it through
  RS4GC successfully; EcoJIT (which additionally runs
  `packFunctionArguments` before `addEcoGCPipeline`) hits the
  `support for FCA unimplemented` assertion deeper into RS4GC's
  `computeLiveInValues`. The IR dumped at the `-emit=llvm` stage
  shows no FCA-typed values, which suggests the FCA is introduced
  somewhere after MLIR-to-LLVM translation in the JIT path. The
  most likely culprit is `packFunctionArguments` (`EcoJIT.cpp:187-235`)
  generating per-function `_mlir_*` wrappers whose interaction with
  the new alloc-uninit + per-field-store call sequences confuses
  RS4GC's liveness analysis. Pinning that down is a prerequisite for
  re-landing the chunk.
- **Chunk 2.3 — `Tuple2/3/ConsConstructOp` lowering switched to
  alloc-uninit + per-field store.** Reverted alongside Chunk 2.2 for
  the same JIT-pipeline reason.
- **Chunk 3 — Wrapper emits `eco.construct.*` directly.** Reverted.
  Independent of the JIT-pipeline issue but kept disabled until the
  wider rework lands because the wrapper-side reroute calls into
  `eco.construct.tuple2` etc., which are themselves the targets of
  Chunk 2.3.
- **Chunk 4 — Lift the all-primitive `eco.return` gate.** Reverted.
  With Chunks 1–3 disabled, the gate remains the only mechanism
  preventing mixed-element aggregate returns from hitting sret +
  wrapper rebox.
- **Chunk 5 — New fixtures.** Not landed.
- **Chunk 6 — Invariant text updates.** Not landed (CGEN_064 /
  CGEN_067 carve-outs remain in `design_docs/invariants.csv`).

### Next steps for re-enable

1. **Reproduce the JIT-only `FCA unimplemented` assertion in
   isolation.** Build a hand-written MLIR fixture that uses
   `eco.construct.tuple2 %a, %b : !eco.value, !eco.value -> !eco.value`
   and run it through EcoRunner (not just `ecoc -emit=llvm`).
   Capture the post-`packFunctionArguments` IR (pre-RS4GC) to see
   exactly which value RS4GC trips on.
2. **Compare to the equivalent `eco_alloc_tuple2`-based IR** (the
   current legacy path) — the same `_mlir_*` wrapper exists for both,
   but only the alloc-uninit + per-field-store sequence fails. The
   diff between the two should localise the responsible pattern
   (likely a live-range interaction between the alloc safepoint's
   `gc.result`, the subsequent `gc-leaf` store calls, and whatever
   the wrapper emits around the function's outer call boundary).
3. **Once isolated, decide the fix.** Options are: (a) adjust the
   alloc-uninit + per-field-store emission to match what RS4GC
   tolerates (e.g., emit a fresh basic block per store); (b) patch
   `packFunctionArguments` to mark its wrappers with the same gc
   attribute as the wrapped function; (c) move `packFunctionArguments`
   to run *after* `addEcoGCPipeline` so RS4GC sees the original
   function signatures.
4. **Re-land Chunks 1 / 2.2 / 2.3 / 3 / 4 / 5 / 6** in the same
   order as the original plan once the JIT-side failure is resolved.

### Pre-existing failure to be aware of

`MVarReadDoesNotEmptyTest` fails reproducibly even with every change
from this plan reverted. The failure mode is the LLVM
`StatepointLowering` assertion
`CallEnd->getOpcode() == ISD::CALLSEQ_END && "expected!"`. Not in
scope for this plan; flagged here so the next implementer doesn't
chase it as a regression of this work.

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
