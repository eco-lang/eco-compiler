# Plan: Centralize GC Root Computation — Explicit Roots on Allocation Ops

## Problem

GC root computation for allocation ops happens in *two places*:

1. **EcoGCPrepare** (`EcoGCPrepare.cpp`) computes live `!eco.value` roots at each allocation group, but only stores a **count** (`eco.gc_roots_count`) — not the actual root values.
2. **EcoToLLVM lowering** (`emitAllocWithSafepoint` in `EcoToLLVMRuntime.cpp:578-625`) re-computes roots via `computeLiveEcoValues()` on the *partially converted* IR, then uses `rewriter.getRemappedValue()` to find i64 equivalents.

The second computation is unreliable because `isEcoValue()` checks `isa<eco::ValueType>(v.getType())`, but by the time `emitAllocWithSafepoint` runs, MLIR's type conversion framework may have already converted `!eco.value` → `i64`, making those values invisible to liveness analysis. The result: missing GC roots, untracked closures, nursery corruption.

In contrast, `eco.safepoint` works correctly because EcoGCPrepare attaches roots as **explicit variadic operands** (`$live_roots`), which flow through the type converter adaptor automatically.

## Goal

Make allocation ops work identically to `eco.safepoint`: roots are computed once in EcoGCPrepare at the Eco IR level and carried as explicit operands through lowering.

## Decisions (resolved)

1. **Per-op casts, not OpInterface.** Use a small `if (auto x = dyn_cast<...>)` chain in EcoGCPrepare. Only ~9 ops need roots; an OpInterface can come later if more ops or passes need the same abstraction.

2. **BoxOp excluded.** `eco.box` for Bool doesn't allocate (embedded constants). For Int/Float/Char it does allocate, but BoxOp is already in `isMayAllocOp` and gets grouped. Rather than adding `live_roots` to BoxOp itself, BoxOp continues to use `emitAllocWithSafepoint` with roots passed from its group leader. **Wait** — actually, BoxOp is lowered individually (each call to `emitAllocWithSafepoint` recomputes roots independently per-op). So BoxOp for Int/Float/Char *does* need roots. The simplest path: **add `live_roots` to BoxOp** but the Bool lowering path simply ignores them. This keeps the 1:1 relationship "every op in `isMayAllocOp` carries roots".

3. **Assembly format mirrors `eco.safepoint`.** Optional parenthesized list before attr-dict:
   ```mlir
   %obj = eco.allocate_ctor(%r0, %r1 : !eco.value, !eco.value)
            { tag = 1, size = 2, scalar_bytes = 0 } : !eco.value
   ```
   Empty roots are omitted (no parens printed).

4. **Move `computeLiveEcoValues` + `isEcoValue` into `EcoGCPrepare.cpp`** as static functions. Remove from `EcoToLLVMRuntime.cpp` and `EcoToLLVMInternal.h`. Lowering must never call them again — this makes accidental reintroduction a compile error.

5. **Elm compiler not affected.** The `eco.allocate_*` and `eco.construct.*` ops are introduced by C++ passes (ConstructLowering, etc.), not by the Elm compiler's MLIR generation. Only `eco.safepoint` is emitted from Elm, and it already works correctly. All op construction sites to update are in C++ only.

---

## Step-by-step Plan

### Phase 1: IR Changes — Add `$live_roots` to allocation ops

**Files:** `runtime/src/codegen/Ops.td`

#### Step 1.1: Add `$live_roots` variadic operand to each allocating op

All 10 ops in `isMayAllocOp` get `Variadic<Eco_Value>:$live_roots`:

**Attribute-only ops** (no existing SSA operands — `live_roots` is the sole operand):
- `Eco_AllocateCtorOp` (line 1035)
- `Eco_AllocateStringOp` (line 1065)
- `Eco_AllocateClosureOp` (line 1083)

```tablegen
let arguments = (ins
    Variadic<Eco_Value>:$live_roots,
    I64Attr:$tag, I64Attr:$size, I64Attr:$scalar_bytes  // existing attrs
);
let assemblyFormat =
    "(`(` $live_roots^ `:` type($live_roots) `)`)? attr-dict `:` type($result)";
```

**Fixed-operand ops** (one variadic + fixed operands — no `AttrSizedOperandSegments` needed):
- `Eco_AllocateOp` (line 1006) — has `$size` (Eco_Int)
- `Eco_BoxOp` — has `$value` (Eco_AnyValue)
- `Eco_ListConstructOp` (line 453) — has `$head`, `$tail`
- `Eco_Tuple2ConstructOp` (line 521) — has `$a`, `$b`
- `Eco_Tuple3ConstructOp` (line 545) — has `$a`, `$b`, `$c`

These have only fixed operands + one new variadic, so ODS can infer segment sizes without `AttrSizedOperandSegments`.

**Two-variadic ops** (need `AttrSizedOperandSegments`):
- `Eco_RecordConstructOp` (line 608) — has `Variadic<Eco_AnyValue>:$fields`
- `Eco_CustomConstructOp` (line 654) — has `Variadic<Eco_AnyValue>:$fields`

These need the `AttrSizedOperandSegments` trait because MLIR can't disambiguate two variadics otherwise. This means `operandSegmentSizes` will appear in the printed IR.

#### Step 1.2: Update assembly formats

Each op's `assemblyFormat` gets an optional `(` $live_roots^ `:` type($live_roots) `)` clause. For Record/Custom, the format must also handle the `operandSegmentSizes` attribute.

#### Step 1.3: Update all C++ op construction sites

Search for all `create<eco::Allocate*Op>`, `create<eco::*ConstructOp>`, `create<eco::BoxOp>` in C++ passes. Each must supply `live_roots` (initially `ValueRange{}`).

Key files to audit:
- `runtime/src/codegen/Passes/ConstructLowering*.cpp` (creates `eco.allocate_ctor`, etc.)
- Any other pass that introduces these ops

These ops are **not** created by the Elm compiler — only by C++ passes.

### Phase 2: EcoGCPrepare — Populate roots on allocation ops

**File:** `runtime/src/codegen/Passes/EcoGCPrepare.cpp`

#### Step 2.1: Move `computeLiveEcoValues` and `isEcoValue` here

Move both functions from `EcoToLLVMRuntime.cpp` into `EcoGCPrepare.cpp` as file-static functions. Remove the declarations from `EcoToLLVMInternal.h` and the implementations from `EcoToLLVMRuntime.cpp`.

#### Step 2.2: Attach root values to allocation group leaders

In `processBlock()`, after computing `liveRoots = computeLiveEcoValues(group.front())`:

Replace the count-only attribute with actual operand population via per-op dyn_cast chain:

```cpp
auto setLiveRoots = [&](Operation *op, ArrayRef<Value> roots) {
    // Per-op dispatch to set live_roots operand
    if (auto x = dyn_cast<AllocateCtorOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<AllocateStringOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<AllocateClosureOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<AllocateOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<BoxOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<ListConstructOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<Tuple2ConstructOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<Tuple3ConstructOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<RecordConstructOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
    else if (auto x = dyn_cast<CustomConstructOp>(op))
        { x.getLiveRootsMutable().clear(); x.getLiveRootsMutable().append(roots); }
};

// In the group loop:
setLiveRoots(group.front(), liveRoots);
```

Keep `eco.gc_roots_count` as a debug-only sanity check attribute (retain existing code, just also set operands).

#### Step 2.3: Allocation grouping unchanged

Group leader carries roots for the entire group. Members marked `eco.gc_group_member` are still skipped in lowering via `isCoalescedGroupMember()`. No change to grouping logic.

### Phase 3: Lowering — Use adaptor roots instead of recomputation

**Files:** `EcoToLLVMRuntime.cpp`, `EcoToLLVMHeap.cpp`, `EcoToLLVMClosures.cpp`, `EcoToLLVMInternal.h`

#### Step 3.1: Change `emitAllocWithSafepoint` signature

```cpp
// Old:
Value emitAllocWithSafepoint(Operation *op, ConversionPatternRewriter &rewriter,
                             const EcoRuntime &runtime,
                             LLVM::LLVMFuncOp allocFunc, ValueRange args);

// New:
Value emitAllocWithSafepoint(Operation *op, ConversionPatternRewriter &rewriter,
                             const EcoRuntime &runtime,
                             LLVM::LLVMFuncOp allocFunc, ValueRange args,
                             ValueRange liveRoots);
```

Update declaration in `EcoToLLVMInternal.h`.

#### Step 3.2: Rewrite `emitAllocWithSafepoint` body

Remove:
- `computeLiveEcoValues(op)` call
- `rewriter.getRemappedValue()` loop

Replace with: directly use the `liveRoots` parameter (already i64 via type converter adaptor) → `IntToPtrOp` → `__eco_safepoint_marker`. This is now identical to what `SafepointOpLowering` does.

```cpp
Value emitAllocWithSafepoint(Operation *op, ConversionPatternRewriter &rewriter,
                             const EcoRuntime &runtime,
                             LLVM::LLVMFuncOp allocFunc, ValueRange args,
                             ValueRange liveRoots) {
    auto loc = op->getLoc();
    auto *ctx = rewriter.getContext();

    if (!liveRoots.empty()) {
        auto gcPtrTy = LLVM::LLVMPointerType::get(ctx, /*addressSpace=*/1);
        SmallVector<Value, 4> gcPtrs;
        for (auto val : liveRoots) {
            auto ptr = rewriter.create<LLVM::IntToPtrOp>(loc, gcPtrTy, val);
            gcPtrs.push_back(ptr);
        }

        runtime.getOrCreateSafepointMarker(rewriter);
        auto voidTy = LLVM::LLVMVoidType::get(ctx);
        auto markerFuncTy = LLVM::LLVMFunctionType::get(voidTy, {}, /*isVarArg=*/true);
        rewriter.create<LLVM::CallOp>(
            loc, markerFuncTy,
            FlatSymbolRefAttr::get(ctx, "__eco_safepoint_marker"),
            gcPtrs);
    }

    auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFunc, args);
    return allocCall.getResult();
}
```

#### Step 3.3: Update all 10 lowering patterns to pass adaptor roots

Each pattern extracts `adaptor.getLiveRoots()` and passes to `emitAllocWithSafepoint`:

```cpp
// Example: AllocateCtorOpLowering
auto liveRoots = adaptor.getLiveRoots();
Value result = emitAllocWithSafepoint(
    op, rewriter, runtime,
    runtime.getOrCreateAllocCustom(rewriter),
    ValueRange{tag, size, scalarBytes},
    liveRoots);
```

**All 10 patterns:**
| Pattern | File | Line |
|---------|------|------|
| `BoxOpLowering` | `EcoToLLVMHeap.cpp` | ~80 |
| `AllocateOpLowering` | `EcoToLLVMHeap.cpp` | ~187 |
| `AllocateCtorOpLowering` | `EcoToLLVMHeap.cpp` | ~217 |
| `AllocateStringOpLowering` | `EcoToLLVMHeap.cpp` | ~251 |
| `ListConstructOpLowering` | `EcoToLLVMHeap.cpp` | ~281 |
| `Tuple2ConstructOpLowering` | `EcoToLLVMHeap.cpp` | ~443 |
| `Tuple3ConstructOpLowering` | `EcoToLLVMHeap.cpp` | ~476 |
| `RecordConstructOpLowering` | `EcoToLLVMHeap.cpp` | (find) |
| `CustomConstructOpLowering` | `EcoToLLVMHeap.cpp` | (find) |
| `AllocateClosureOpLowering` | `EcoToLLVMClosures.cpp` | ~87 |

**Special case — BoxOp for Bool:** The Bool path (line 116-122) uses `SelectOp` and never calls `emitAllocWithSafepoint`, so adaptor roots are simply unused. No special handling needed.

#### Step 3.4: Remove dead code from lowering

- Remove `computeLiveEcoValues` implementation from `EcoToLLVMRuntime.cpp`
- Remove `isEcoValue` implementation from `EcoToLLVMRuntime.cpp`
- Remove declarations of both from `EcoToLLVMInternal.h`

These now live exclusively in `EcoGCPrepare.cpp`.

### Phase 4: Verification & Testing

#### Step 4.1: Debug assertion in `emitAllocWithSafepoint`

```cpp
#ifndef NDEBUG
if (auto rootCount = op->getAttrOfType<IntegerAttr>("eco.gc_roots_count"))
    assert(liveRoots.size() == (size_t)rootCount.getInt() &&
           "root count mismatch between EcoGCPrepare and lowering");
#endif
```

#### Step 4.2: MLIR FileCheck tests

Create test(s) that verify:
- After `eco-gc-prepare` pass: allocation ops carry correct root operands (FileCheck the `live_roots` in printed MLIR)
- After EcoToLLVM lowering: `__eco_safepoint_marker` around allocations has correct gc pointer args
- The marker+alloc pattern matches what StatepointConversion expects

#### Step 4.3: Run E2E test suite

```bash
cmake --build build --target full
```

Verify no regressions. The crashing case (mid-function closure allocation → nursery GC) should now pass because roots are tracked correctly.

### Phase 5: Cleanup

#### Step 5.1: Remove temporary debug scaffolding

Once E2E tests pass reliably:
- Consider removing `eco.gc_roots_count` attribute entirely (or gate behind `NDEBUG`)
- Keep the assertion in `emitAllocWithSafepoint` as a permanent debug-mode check
- Remove any heavy IR dump logging around allocations

---

## Affected Files Summary

| File | Changes |
|------|---------|
| `runtime/src/codegen/Ops.td` | Add `$live_roots` to 10 ops; `AttrSizedOperandSegments` for Record/Custom |
| `runtime/src/codegen/Passes/EcoGCPrepare.cpp` | Move liveness functions here; populate `live_roots` on alloc ops |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | Rewrite `emitAllocWithSafepoint`; remove `computeLiveEcoValues`/`isEcoValue` |
| `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp` | Update 9 lowering patterns to pass `adaptor.getLiveRoots()` |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | Update `AllocateClosureOpLowering` |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | Update `emitAllocWithSafepoint` decl; remove liveness decls |
| C++ passes that create alloc ops | Supply `ValueRange{}` for `live_roots` at construction |
| `.mlir` test files | Update expected IR for new operand syntax |

## Assumptions

- **Allocation grouping stays unchanged.** Group leader carries roots for the entire group; members are coalesced.
- **`computeLiveEcoValues` is correct at the Eco IR level.** The liveness analysis itself is sound; the bug is only that it runs too late.
- **StatepointConversion needs no changes.** It already recognizes `eco_alloc_*` as valid statepoint targets.
- **Elm compiler not affected.** All `eco.allocate_*` / `eco.construct.*` ops are introduced by C++ passes, not Elm codegen.
- **No new invariants needed.** This aligns allocation safepoints with poll safepoints, which already work correctly.

## Risks

- **ODS changes to 10 ops** touch generated code and assembly formats. Existing `.mlir` test files will need format updates.
- **`AttrSizedOperandSegments`** on Record/Custom adds `operandSegmentSizes` to printed IR, changing test expectations.
- **C++ op construction sites** must all be found and updated. Missing sites will cause compile errors (safe to detect, but may be scattered across passes).
