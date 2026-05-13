# Plan: Projection Helpers Everywhere — gc-leaf runtime helpers for heap projections

## Problem

EcoToLLVM currently lowers heap projections that return **unboxed primitives**
(`i64`, `f64`, `i16`) into a three-step sequence directly in the user IR:

```mlir
%p = call @eco_resolve_hptr(%hptr)
%fp = llvm.getelementptr %p, <offset>
%v  = llvm.load %fp : <primTy>
```

This pattern is reproduced in five lowerings in
`runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`:

| Op | Lowering | Lines |
|---|---|---|
| `eco.project.list_head` | `ListHeadOpLowering` | 335-392 (primitive branches already use `eco_cons_head_*` helpers; the `!eco.value` branch still emits resolve+gep+load) |
| `eco.project.list_tail` | `ListTailOpLowering` | 398-429 |
| `eco.project.tuple2` | `Tuple2ProjectOpLowering` | 527-567 |
| `eco.project.tuple3` | `Tuple3ProjectOpLowering` | 573-612 |
| `eco.project.record` | `RecordProjectOpLowering` | 691-730 |
| `eco.project.custom` | `CustomProjectOpLowering` | 814-853 |

When a `load` of a primitive (e.g. `i64`/`f64`/`i16`) appears in user IR between
two statepoints, LLVM's RS4GC + later code-motion can rematerialize the
underlying pointer arithmetic *past a statepoint*, then reload from a stale heap
address. This is "Pattern C" in `mlir-equivalence-report.md`: tuple2 projections
of an `i64` (the `consumerIdx` slot in the mutual-recursion closure setup) come
back as garbage HPointer-pattern bits in the `cross_edges` array.

The workaround currently applied at
`compiler/src/Compiler/Generate/MLIR/Expr.elm:4504-4505`:

```elm
consumerIdxLocal =
    consumerIdx + 0
```

forces an extra in-scope arithmetic use to keep the primitive value live, but
this is fragile and treats the symptom, not the cause.

## Goal

For every heap-backed Eco projection that produces an **unboxed primitive** type
(`i64`, `f64`, `i16`), lower to **exactly one `llvm.call` to a gc-leaf runtime
helper**. The resolve + gep + load sequence moves *inside* the runtime helper
where LLVM cannot rematerialize it across a statepoint.

The `!eco.value` (boxed HPtr) branches stay as-is: boxed pointers travel through
RS4GC via the existing relocation machinery and Pattern C does not apply.

This systematically extends the design already in use for:

- `eco_get_tag(HPtr) -> i32` (declared at `RuntimeExports.h:536`, used by
  `GetTagOpLowering` at `EcoToLLVMControlFlow.cpp:43-63`)
- `eco_cons_head_{i64,f64,i16}(HPtr)` (declared at `RuntimeExports.h:548-564`,
  used by `ListHeadOpLowering` at `EcoToLLVMHeap.cpp:354-371`)

…to cover the remaining tuple/record/custom unboxed primitive projection cases.

## Decisions (resolved)

1. **Only primitive return types go through new helpers.** Boxed
   (`!eco.value` → `ptr addrspace(1)`) result branches keep the existing
   `eco_resolve_hptr + gep + llvm.load i64 + heapLoadI64ToValue` path. Boxed
   pointers are GC-safe under RS4GC; Pattern C is exclusively about unboxed
   primitives being rematerialized past safepoints.

2. **Helpers are gc-leaf and non-allocating.** Each new helper is declared with
   `gcLeaf=true` in `EcoToLLVMRuntime.cpp`, matching `eco_get_tag` and
   `eco_cons_head_*`. The helper body is a short `Allocator::resolve` +
   field load with no allocation and no GC trigger.

3. **Helper bodies reuse layout constants from `EcoToLLVMInternal.h`.**
   `Tuple2FirstOffset`, `Tuple3FirstOffset`, `RecordFieldsOffset`,
   `CustomFieldsOffset`, `ArrayElementsOffset`, `PtrSize` — already defined
   under `namespace layout` (lines 202-242). The helper bodies access slots
   via `static_cast<uint8_t*>(obj) + layout::FooOffset + idx * PtrSize`
   rather than re-deriving offsets, and the **same constants** are used by
   the corresponding lowering for any non-helper paths. No duplicated layout
   math.

4. **Tuple/record/custom helpers read the slot unconditionally as the
   requested primitive type. `eco_cons_head_*` keeps its dual boxed/unboxed
   path; the new helpers do not.** Per heap-representation theory and the
   2-bit unboxed kind bitmap on construct ops, each slot's stored
   representation is consistent with the SSA type of the operand at
   construct time: an `i64`-typed slot is always stored as the unboxed
   `i.value`, never as a boxed `ElmInt`. Lists are special because legacy
   code paths can present either layout, which is why `eco_cons_head_*`
   already dual-paths via `tupleFieldKind(hdr->unboxed, 0)`. New helpers do
   not need to replicate that.

5. **No `_hptr`-returning helpers for tuple/record/custom.** Boxed branches
   in lowering stay unchanged (per decision 1), so those declarations would
   be dead code. Only `_i64` / `_f64` / `_i16` variants are introduced.

6. **No tuple `_hptr` either; no helpers for `list_tail`.** Same rationale —
   `list_tail` always returns `!eco.value` (boxed) and is not implicated in
   Pattern C. Leave it untouched.

7. **`i1` projection is treated as a hard error, not a silent fallback.**
   Bool is always `!eco.value` in heap and closure storage (per REP_*
   invariants in `design_docs/invariants.csv`); the front-end must lower
   `project -> i1` as `project -> !eco.value` then `eco.unbox`. Today the
   existing `else`-branch in tuple/record/custom projection does
   `LLVM::LoadOp(loc, resultType, fieldPtr)`, which for `i1` reads only the
   low bit of an i64 slot — silently wrong. The new lowering emits
   `op.emitOpError("unsupported primitive type for eco.project.* — Bool
   must go through !eco.value + eco.unbox")` for any non-{i64,f64,i16,
   !eco.value} type. `notifyMatchFailure` was rejected because it allows a
   later pattern to claim the op and hide the representation bug.

8. **Record/custom field index width: i32.** Existing layout uses i32 field
   indices in `eco_store_record_field` / `eco_init_record_at`. The projection
   ops carry an `I64Attr:$field_index` (Ops.td:704, 777). The lowering
   materializes an `i32` constant from the attribute (no SSA truncation
   needed — it is an attribute, not a value).

9. **`eco.array.get` is in scope.** Same gc-leaf-helper pattern as
   record/custom projection, but the index is an SSA `Eco_Int` operand
   (Ops.td:787-808) rather than an attribute, so the helper signature takes
   `(HPtr, i64 index)`. Boxed (`!eco.value`) result path is left alone;
   primitive (`i64`/`f64`/`i16`) paths go through helpers. `eco.array.set`
   is **out of scope** for this change (it allocates a new array, so the
   resolve+gep+store happens during a path that is already statepoint-safe
   on the allocation side; revisit only if a separate Pattern-C-like issue
   is observed).

10. **Helper symbol naming follows existing convention.**
    `eco_tuple2_get{0,1}_{i64,f64,i16}`,
    `eco_tuple3_get{0,1,2}_{i64,f64,i16}`,
    `eco_record_get_{i64,f64,i16}(HPtr, u32)`,
    `eco_custom_get_{i64,f64,i16}(HPtr, u32)`,
    `eco_array_get_{i64,f64,i16}(HPtr, i64)`.

11. **Removing the `consumerIdx + 0` workaround is part of this change.**
    Without it we lose evidence that the helper-based lowering actually
    fixes Pattern C. Removal happens in the same commit as the lowering
    switch so bisection lands on the real cause.

12. **Many small helpers, not one polymorphic dispatcher.** 24 new symbols
    (15 tuple + 6 record/custom + 3 array) and 24 new `getOrCreate*`
    methods. Each is one resolve + one load, trivially gc-leaf, no dynamic
    kind dispatch. Matches the existing `eco_cons_head_{i64,f64,i16}`
    split. `alwaysinline` is **not** set today — preserving the call
    boundary is part of the Pattern C fix — but can be revisited under LTO
    later, since gc-leaf + non-allocating means RS4GC will still treat
    inlined code as safe.

---

## Step-by-step plan

### Phase 1 — Runtime helpers

**Files:** `runtime/src/allocator/RuntimeExports.h`, `runtime/src/allocator/RuntimeExports.cpp`

#### Step 1.1 — Declare helpers in `RuntimeExports.h`

Just after the existing "List Element Access" block (around line 564), add
three new sections:

```c
//===----------------------------------------------------------------------===//
// Tuple field access (gc-leaf, non-allocating).
// Reads the slot unconditionally as the requested primitive type. Per the
// 2-bit unboxed kind bitmap, an `i64`-typed Int slot is always stored as the
// unboxed `i` union member, etc. — no dual boxed/unboxed path needed (unlike
// eco_cons_head_*).
//===----------------------------------------------------------------------===//

int64_t eco_tuple2_get0_i64(HPtr tup);
int64_t eco_tuple2_get1_i64(HPtr tup);
double  eco_tuple2_get0_f64(HPtr tup);
double  eco_tuple2_get1_f64(HPtr tup);
int16_t eco_tuple2_get0_i16(HPtr tup);
int16_t eco_tuple2_get1_i16(HPtr tup);

int64_t eco_tuple3_get0_i64(HPtr tup);
int64_t eco_tuple3_get1_i64(HPtr tup);
int64_t eco_tuple3_get2_i64(HPtr tup);
double  eco_tuple3_get0_f64(HPtr tup);
double  eco_tuple3_get1_f64(HPtr tup);
double  eco_tuple3_get2_f64(HPtr tup);
int16_t eco_tuple3_get0_i16(HPtr tup);
int16_t eco_tuple3_get1_i16(HPtr tup);
int16_t eco_tuple3_get2_i16(HPtr tup);

//===----------------------------------------------------------------------===//
// Record / Custom field access (gc-leaf, non-allocating)
//===----------------------------------------------------------------------===//

int64_t eco_record_get_i64(HPtr rec, uint32_t field_index);
double  eco_record_get_f64(HPtr rec, uint32_t field_index);
int16_t eco_record_get_i16(HPtr rec, uint32_t field_index);

int64_t eco_custom_get_i64(HPtr val, uint32_t field_index);
double  eco_custom_get_f64(HPtr val, uint32_t field_index);
int16_t eco_custom_get_i16(HPtr val, uint32_t field_index);

//===----------------------------------------------------------------------===//
// Array element access (gc-leaf, non-allocating).
// Index is `int64_t` to mirror `Eco_Int` SSA operand on `eco.array.get`.
//===----------------------------------------------------------------------===//

int64_t eco_array_get_i64(HPtr arr, int64_t index);
double  eco_array_get_f64(HPtr arr, int64_t index);
int16_t eco_array_get_i16(HPtr arr, int64_t index);
```

#### Step 1.2 — Implement helpers in `RuntimeExports.cpp`

Implement just after the existing `eco_cons_head_*` block. Helper bodies use
**byte offsets via the layout constants** (`Tuple2FirstOffset`,
`Tuple3FirstOffset`, `RecordFieldsOffset`, `CustomFieldsOffset`,
`ArrayElementsOffset`, `PtrSize`) rather than C++ struct field accesses, so
the layout source of truth stays in `EcoToLLVMInternal.h` rather than being
duplicated across `Heap.hpp` struct layouts and helper bodies.

> Note: the layout namespace currently lives only inside the EcoToLLVM
> internal header; helpers in `runtime/src/allocator/` should pick up the
> same constants. If `EcoToLLVMInternal.h` is not directly includable from
> the allocator TU, either (a) hoist `namespace eco::layout` into a small
> shared header reachable from both sides, or (b) define a mirror constant
> set on the allocator side with a `static_assert` cross-check. Pick the
> path with the fewer build-graph contortions — decision deferred to the
> implementer once the include graph is inspected.

Pattern, illustrated for `tuple2_get0_i64`:

```c++
extern "C" int64_t eco_tuple2_get0_i64(HPtr tup) {
    HPointer hp = tup.toHPointer();
    void* obj = Allocator::instance().resolve(hp);
    assert(obj != nullptr && "eco_tuple2_get0_i64: null resolve");
    auto* slot = reinterpret_cast<int64_t*>(
        static_cast<uint8_t*>(obj) + layout::Tuple2FirstOffset + 0 * layout::PtrSize);
    return *slot;
}
```

with `_f64` variants reinterpret-casting to `double*`, and `_i16` variants
loading the i64 slot and truncating (matching how `ArrayGetOpLowering`
truncates today, line 957): `return static_cast<int16_t>(*slot_i64);`. Same
skeleton for `tuple3` (offsets `Tuple3FirstOffset + index*PtrSize`).

Record / custom:

```c++
extern "C" int64_t eco_record_get_i64(HPtr rec, uint32_t field_index) {
    HPointer hp = rec.toHPointer();
    void* obj = Allocator::instance().resolve(hp);
    assert(obj != nullptr && "eco_record_get_i64: null resolve");
    auto* slot = reinterpret_cast<int64_t*>(
        static_cast<uint8_t*>(obj)
        + layout::RecordFieldsOffset
        + size_t(field_index) * layout::PtrSize);
    return *slot;
}
```

`_f64` casts the slot pointer to `double*`; `_i16` loads i64 and truncates.
Custom variants are identical modulo `RecordFieldsOffset` → `CustomFieldsOffset`.

Array:

```c++
extern "C" int64_t eco_array_get_i64(HPtr arr, int64_t index) {
    HPointer hp = arr.toHPointer();
    void* obj = Allocator::instance().resolve(hp);
    assert(obj != nullptr && "eco_array_get_i64: null resolve");
    auto* slot = reinterpret_cast<int64_t*>(
        static_cast<uint8_t*>(obj)
        + layout::ArrayElementsOffset
        + size_t(index) * layout::PtrSize);
    return *slot;
}
```

ArrayGet's current lowering (`EcoToLLVMHeap.cpp:912-964`) already loads i64
and then truncates/bitcasts based on result type; the new helpers preserve
that shape internally.

**Invariant:** none of these allocate, none take locks, none can trigger GC.
They mirror the contract of `eco_get_tag` / `eco_cons_head_*`.

### Phase 2 — EcoRuntime declarations

**Files:** `runtime/src/codegen/Passes/EcoToLLVMInternal.h`,
`runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp`

#### Step 2.1 — Add `getOrCreate*` declarations

In `EcoToLLVMInternal.h`, just after `getOrCreateConsHeadI16` (line 397), add:

```c++
// Tuple2 / Tuple3 unboxed-primitive field accessors
mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get0I64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get1I64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get0F64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get1F64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get0I16(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple2Get1I16(mlir::OpBuilder &builder) const;

mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get0I64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get1I64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get2I64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get0F64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get1F64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get2F64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get0I16(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get1I16(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateTuple3Get2I16(mlir::OpBuilder &builder) const;

// Record / Custom unboxed-primitive field accessors (HPtr, i32) -> prim
mlir::LLVM::LLVMFuncOp getOrCreateRecordGetI64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateRecordGetF64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateRecordGetI16(mlir::OpBuilder &builder) const;

mlir::LLVM::LLVMFuncOp getOrCreateCustomGetI64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateCustomGetF64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateCustomGetI16(mlir::OpBuilder &builder) const;

// Array unboxed-primitive element accessors (HPtr, i64) -> prim
mlir::LLVM::LLVMFuncOp getOrCreateArrayGetI64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateArrayGetF64(mlir::OpBuilder &builder) const;
mlir::LLVM::LLVMFuncOp getOrCreateArrayGetI16(mlir::OpBuilder &builder) const;
```

#### Step 2.2 — Define them in `EcoToLLVMRuntime.cpp`

After the `getOrCreateConsHeadI16` definition (line 505-510), add the
corresponding `getOrCreate*` definitions. Each follows the same one-line
pattern as `getOrCreateConsHeadI64` (line 492-496), using the existing
`HPTR_TY` / `I64_TY` / `F64_TY` / `I16_TY` / `I32_TY` macros and passing
`gcLeaf=true`:

```c++
LLVM::LLVMFuncOp EcoRuntime::getOrCreateTuple2Get0I64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY});
    return getOrCreateFunc(builder, "eco_tuple2_get0_i64", funcTy, /*gcLeaf=*/true);
}
// ...etc for the other 14 tuple variants

LLVM::LLVMFuncOp EcoRuntime::getOrCreateRecordGetI64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY, I32_TY});
    return getOrCreateFunc(builder, "eco_record_get_i64", funcTy, /*gcLeaf=*/true);
}
// ...etc for record_get_f64/i16 and custom_get_*

LLVM::LLVMFuncOp EcoRuntime::getOrCreateArrayGetI64(OpBuilder &builder) const {
    auto funcTy = LLVM::LLVMFunctionType::get(I64_TY, {HPTR_TY, I64_TY});
    return getOrCreateFunc(builder, "eco_array_get_i64", funcTy, /*gcLeaf=*/true);
}
// ...etc for array_get_f64/i16
```

No CMake changes needed; `EcoToLLVMRuntime.cpp` is already in the EcoPasses
sources list.

### Phase 3 — Switch lowerings to call helpers

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp`

#### Step 3.1 — Add a small primitive-kind dispatcher utility

Near the top of the file (alongside `isHPtrLLVMType`, `heapLoadI64ToValue`,
`widenFieldToI64`), add a static helper that picks the right `LLVMFuncOp` from
a `{result type, field index}` pair for tuple2/tuple3, and a similar one for
record/custom. Keeping this inline in each pattern (3 nested ifs each) is also
acceptable; choose whichever reads cleaner once written. The aim is no
duplicated `isI64 / isF64 / isI16` switch in four nearly-identical bodies.

#### Step 3.2 — `Tuple2ProjectOpLowering` (lines 527-567)

Replace the primitive `else` branch (lines 561-564) with a single helper
dispatch. The boxed branch (lines 557-560) is unchanged.

Sketch:

```c++
Type resultType = getTypeConverter()->convertType(op.getResult().getType());
if (isHPtrLLVMType(resultType)) {
    // ...existing resolve+GEP+load i64+heapLoadI64ToValue path
    return success();
}

int64_t field = op.getField();
LLVM::LLVMFuncOp callee;
if (resultType.isInteger(64))
    callee = (field == 0) ? runtime.getOrCreateTuple2Get0I64(rewriter)
                          : runtime.getOrCreateTuple2Get1I64(rewriter);
else if (resultType.isF64())
    callee = (field == 0) ? runtime.getOrCreateTuple2Get0F64(rewriter)
                          : runtime.getOrCreateTuple2Get1F64(rewriter);
else if (resultType.isInteger(16))
    callee = (field == 0) ? runtime.getOrCreateTuple2Get0I16(rewriter)
                          : runtime.getOrCreateTuple2Get1I16(rewriter);
else
    return op.emitOpError("unsupported primitive type for eco.project.tuple2 — "
                          "Bool must go through !eco.value + eco.unbox");

auto call = rewriter.create<LLVM::CallOp>(loc, callee, ValueRange{input});
rewriter.replaceOp(op, call.getResult(0));
return success();
```

The resolve + GEP + load sequence is deleted from the primitive path. The
boxed path keeps its own resolve+load since heap slots store i64 and we then
go through `heapLoadI64ToValue`. `emitOpError` is used instead of
`notifyMatchFailure` so that an `i1` projection (or any other unhandled
primitive width) surfaces loudly rather than being claimed by some later
fallback pattern.

#### Step 3.3 — `Tuple3ProjectOpLowering` (lines 573-612)

Same shape as tuple2 but with a `switch (field)` over `{0, 1, 2}` for each
primitive type. Boxed branch unchanged. Unsupported primitive widths go
through `op.emitOpError(...)` the same way as tuple2.

#### Step 3.4 — `RecordProjectOpLowering` (lines 691-730)

Replace the primitive branch with a `(HPtr, i32 field)` helper call:

```c++
Type resultType = getTypeConverter()->convertType(op.getResult().getType());
if (isHPtrLLVMType(resultType)) {
    // ...existing path
    return success();
}

auto i32Ty = IntegerType::get(ctx, 32);
auto fieldIdx = rewriter.create<LLVM::ConstantOp>(loc, i32Ty,
                    static_cast<int32_t>(op.getFieldIndex()));

LLVM::LLVMFuncOp callee;
if (resultType.isInteger(64))      callee = runtime.getOrCreateRecordGetI64(rewriter);
else if (resultType.isF64())       callee = runtime.getOrCreateRecordGetF64(rewriter);
else if (resultType.isInteger(16)) callee = runtime.getOrCreateRecordGetI16(rewriter);
else return op.emitOpError("unsupported primitive type for eco.project.record — "
                           "Bool must go through !eco.value + eco.unbox");

auto call = rewriter.create<LLVM::CallOp>(loc, callee,
                ValueRange{input, fieldIdx});
rewriter.replaceOp(op, call.getResult(0));
return success();
```

Delete the `LLVM::LoadOp` of `resultType` on the primitive branch.

#### Step 3.5 — `CustomProjectOpLowering` (lines 814-853)

Same as `RecordProjectOpLowering`, dispatching to `getOrCreateCustomGet*`.
`emitOpError` on unsupported primitive widths, same wording.

#### Step 3.6 — `ArrayGetOpLowering` (lines 904-965)

Today builds the element pointer inline (`resolve + base+index*8 + load i64 +
bitcast/trunc/heapLoadI64ToValue`). Restructure so that:

- Boxed result (`isa<eco::ValueType>(origResultType)`, lines 943-945) keeps
  the existing resolve+GEP+load+`heapLoadI64ToValue` path.
- Primitive (`i64`/`f64`/`i16`) results call the new helper:

```c++
Type origResultType = op.getResult().getType();
if (isa<eco::ValueType>(origResultType)) {
    // ...existing boxed path (resolve + GEP + load i64 + heapLoadI64ToValue)
    return success();
}

LLVM::LLVMFuncOp callee;
if (origResultType.isInteger(64))      callee = runtime.getOrCreateArrayGetI64(rewriter);
else if (origResultType.isF64())       callee = runtime.getOrCreateArrayGetF64(rewriter);
else if (origResultType.isInteger(16)) callee = runtime.getOrCreateArrayGetI16(rewriter);
else return op.emitOpError("unsupported element type for eco.array.get");

auto call = rewriter.create<LLVM::CallOp>(loc, callee,
                ValueRange{arrayVal, indexVal});
rewriter.replaceOp(op, call.getResult(0));
return success();
```

The internal bitcast (i64→f64) and truncate (i64→i16) move into the helper
body; they are no longer visible in user IR.

`eco.array.set` (`ArraySetOpLowering`, lines 971+) is **out of scope** for
this change — it allocates and then stores, and is not implicated in Pattern
C. Revisit only if a follow-up issue surfaces.

#### Step 3.7 — `ListHeadOpLowering` (lines 335-392)

Already uses `eco_cons_head_*` for `i64/f64/i16` (lines 354-371). **No
behavior change** — but verify that no further primitive widths sneak through:
the trailing path for `!eco.value` (lines 374-389) is the boxed branch and
stays. This step is a sanity-check, not a code change.

#### Step 3.8 — `ListTailOpLowering` (lines 398-429)

**No change.** Always returns `!eco.value`; not implicated in Pattern C. Leave
as-is for now; revisit only if a future regression demonstrates a need.

#### Step 3.9 — `GetTagOpLowering` (`EcoToLLVMControlFlow.cpp:43-63`)

**No change.** Already calls `eco_get_tag` via `getOrCreateGetTag`. Verified.

### Phase 4 — Remove the Expr.elm workaround

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

At line 4504-4505, the workaround:

```elm
consumerIdxLocal =
    consumerIdx + 0
```

…and its uses at lines 4516 etc., should be folded back to use `consumerIdx`
directly. Update the surrounding comment block (lines 4498-4503) to be
deleted — it documents a symptom we are now removing.

This change must be in the **same commit** as the lowering switch in Phase 3
so that any reintroduction of Pattern C bisects to one well-defined cause.

### Phase 5 — Tests

**Location:** `runtime/test/codegen/` (alongside existing EcoToLLVM FileCheck
fixtures referenced in the escape-analysis design doc — `value_tuple2.mlir`,
`value_record3.mlir`, etc.).

#### Step 5.1 — Codegen FileCheck tests

Add four new tests asserting helper-shape lowering and the absence of
resolve+gep+load on primitive paths.

`project_tuple2_helpers.mlir` / `project_tuple3_helpers.mlir`:

```mlir
func.func @tuple2_i64(%t: !eco.value) -> i64 {
  %0 = eco.project.tuple2 %t[0] : !eco.value -> i64
  func.return %0 : i64
}
// CHECK-LABEL: @tuple2_i64
// CHECK: llvm.call @eco_tuple2_get0_i64
// CHECK-NOT: llvm.call @eco_resolve_hptr
// CHECK-NOT: llvm.load
```

Repeat for `tuple2[1]`, all three `tuple3` indices, and for `f64`/`i16`
results.

`project_record_helpers.mlir` / `project_custom_helpers.mlir`:

```mlir
func.func @rec_i64(%r: !eco.value) -> i64 {
  %0 = eco.project.record %r[2] : !eco.value -> i64
  func.return %0 : i64
}
// CHECK: llvm.call @eco_record_get_i64
// CHECK-NOT: llvm.call @eco_resolve_hptr
```

Same shape for custom (`eco_custom_get_*`).

`array_get_helpers.mlir`:

```mlir
func.func @arr_i64(%a: !eco.value, %i: i64) -> i64 {
  %0 = eco.array.get %a[%i] : i64
  func.return %0 : i64
}
// CHECK: llvm.call @eco_array_get_i64
// CHECK-NOT: llvm.call @eco_resolve_hptr
// CHECK-NOT: llvm.load
```

…and `f64` / `i16` variants.

`project_boxed_unchanged.mlir`:

```mlir
func.func @tuple2_boxed(%t: !eco.value) -> !eco.value {
  %0 = eco.project.tuple2 %t[0] : !eco.value -> !eco.value
  func.return %0 : !eco.value
}
// CHECK: llvm.call @eco_resolve_hptr
// CHECK: llvm.load {{.*}} : !llvm.ptr -> i64
// CHECK-NOT: llvm.call @eco_tuple2_get0
```

…to lock in that the boxed path is deliberately not switched.

#### Step 5.2 — Pattern C regression coverage

Run the existing `run-mlir-equivalence` suite (the three MutualLetRec tests
referenced in `mlir-equivalence-report.md`) with the `consumerIdx + 0`
workaround removed. They should pass; before this change they only pass with
the workaround applied. Capture this as a checklist item; no new test file
needed if the suite already covers it.

#### Step 5.3 — Full E2E

`cmake --build build --target full` once, redirecting to
`/tmp/test_output.txt`. Verify no regressions, particularly in tests touching
records, customs, and tuples with primitive fields.

---

## Open issues / implementer notes

All seven of the original open questions have been resolved (see "Decisions"
section above and the user's reply to the prior PQN round). Two small items
remain to be settled during implementation:

1. **Layout constants reachable from `runtime/src/allocator/`.** The
   `namespace eco::layout` (with `Tuple2FirstOffset`, `RecordFieldsOffset`,
   `CustomFieldsOffset`, `ArrayElementsOffset`, `PtrSize`, etc.) lives in
   `runtime/src/codegen/Passes/EcoToLLVMInternal.h`, which is internal to
   the EcoToLLVM pass library. `RuntimeExports.cpp` lives in
   `runtime/src/allocator/` and may or may not be in the include reach of
   that header.

   Two acceptable resolutions, decision deferred to whoever inspects the
   build graph:
   - **(a)** Hoist `namespace eco::layout` into a small shared header that
     both the EcoToLLVM pass and the allocator can include (e.g.
     `runtime/src/common/HeapLayout.hpp`). Preferred if no circular include
     issues result; keeps a single source of truth.
   - **(b)** Mirror the constants on the allocator side (e.g. inside
     `runtime/src/allocator/HeapLayoutConstants.hpp`) and assert agreement
     in *one* place via `static_assert`s that include both headers. Fall
     back here if (a) tangles the build graph.

2. **`alwaysinline` is intentionally not set.** The helpers are `gc-leaf` but
   stay as real calls in the optimized IR. This is load-bearing for the
   Pattern C fix: the call boundary is what prevents LLVM from sinking the
   underlying load past a statepoint. Once LTO is on and we have evidence
   that the per-call cost matters in a real workload, we can re-evaluate —
   gc-leaf + non-allocating means RS4GC will still treat inlined code as
   safe, so the relaxation is a knob, not a redesign.

---

## Summary

After this change:

- `eco.project.tuple2`, `eco.project.tuple3`, `eco.project.record`,
  `eco.project.custom`, `eco.project.list_head`, and `eco.array.get` lower
  to a single gc-leaf `llvm.call` whenever the result is `i64`/`f64`/`i16`.
- `eco.get_tag` already lowers via `eco_get_tag` (no change).
- Boxed `!eco.value` projection paths, `eco.project.list_tail`, and
  `eco.array.set` are deliberately unchanged.
- The `consumerIdx + 0` workaround in `Expr.elm:4504` is removed in the same
  commit, providing a non-bypassed Pattern C regression test.
- `i1` projection from heap is rejected with `op.emitOpError` — the Bool-as-
  heap-primitive bug becomes loud at lowering time instead of silently
  reading one bit of an i64 slot.
- 24 new runtime symbols (15 tuple + 6 record/custom + 3 array) and 24 new
  `getOrCreate*` declarations. Each helper is one resolve + one field read;
  none allocate or trigger GC. Helper bodies share layout constants with the
  EcoToLLVM pass via `eco::layout::*`.
