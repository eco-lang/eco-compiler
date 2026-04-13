# Stack Root Ranges for Args-Array GC Safety

## Problem

When EcoToLLVM lowering builds `alloca`-backed `i64` arrays to marshal HPointer
arguments for runtime calls (`eco_apply_closure`, `eco_pap_extend`,
`eco_apply_segmentation_unknown`, `eco_closure_call_saturated`), these arrays are
invisible to the GC. If a GC fires inside those runtime calls (or during boxing
calls that populate the arrays), any HPointers already stored in the array become
stale — the GC relocates the target objects but the array copies still hold the
pre-GC addresses. This causes the bootstrap corruption: `0x2d002d002d002d` values,
bogus `new_n_values`, and `obj < heap_end` assertion failures.

## Approach

Add a "root range" concept to `RootSet` so the GC can scan contiguous arrays of
`i64` values stored in stack allocas. Zero-initialize arrays before registration
so uninitialized slots are harmless (the GC's existing `isInNursery`/`isInHeap`
bounds checks skip non-heap values). Expose a small C ABI for compiled code and
instrument every args-array call site in `EcoToLLVMClosures.cpp`.

### Design Decisions (resolved)

**Bitmap vs scan-all:** The `StackRootRange` struct retains an `hpointer_mask`
field and this mask is **mandatory for correctness** on mixed arrays. A random
`i64` can fall inside the heap / nursery address range, so we cannot safely
"scan all" and rely purely on address-range checks.

- For **mixed arrays**, `hpointer_mask` encodes exactly which slots are boxed
  HPointers. Only slots with bit `i` set are treated as roots.
- For **all-boxed arrays**, `hpointer_mask` is computed as
  `(1ULL << count) - 1`, so every slot is treated as a root, equivalent to
  scanning all slots.
- The GC still applies `isInNursery` / `isInHeap` checks before following or
  copying a root; the mask just prevents raw `i64`s from ever being presented
  as candidate pointers.

Zero-initialization remains required so that masked-in slots that have not yet
been populated contain `0`, which safely fails the heap/nursery checks.

**Early registration:** The range is registered BEFORE the population loop, not
just before the final runtime call. Boxing calls (`eco_alloc_*`) during
population can trigger GC, so HPointers stored at earlier array indices must
already be roots. Zero-init ensures unfilled slots are safe at any GC point.

**`emitClosureCall` (dispatch_mode="closure"):** Safe as-is. It passes args as
direct LLVM `CallOp` operands (SSA values tracked by statepoints), no alloca
args array.

**Nesting:** `stackRangePoint`/`restoreStackRangePoint` is stack-disciplined,
same growth model as existing `stack_roots`. Arbitrary nesting is safe.

**C ABI type:** `uint64_t*` for consistency with existing `eco_gc_add_root`.

**Count limit:** Assert `count <= 64` in debug builds. If exceeded (should never
happen — Elm closure arities are < 10), fall back to pushing individual
`stack_roots`. See Step 6 overflow handling.

---

## Call Sites Requiring Instrumentation

There are **4 distinct runtime call patterns** that use args arrays, across
**3 code paths** in `EcoToLLVMClosures.cpp`:

| # | Function | Code Path | Array Type | Line |
|---|----------|-----------|------------|------|
| 1 | `eco_apply_segmentation_unknown` | `lowerSegmentationUnknown` | `typedArgsArray` (mixed) + `boxedArgsArray` (all HPtr) | 968 |
| 2 | `eco_apply_closure` | `lowerGenericApply` | `argsArray` (all HPtr, boxed) | 1063 |
| 3 | `eco_closure_call_saturated` | `emitInlineClosureCall` | `newArgsArray` (all HPtr, boxed) | 788 |
| 4 | `eco_pap_extend` | `PapExtendOpLowering` (partial-app branch) | `argsArray` (mixed, has bitmap) | 1174 |

**Mixed-type arrays** (sites 1-typed, 4): contain raw i64 Ints alongside
HPointers, distinguished by `newargsUnboxedBitmap`. The `hpointer_mask` records
which slots are HPointers (inverted unboxed bitmap) and is **mandatory for
correctness** — the GC only scans masked slots.

**Boxed arrays** (sites 1-boxed, 2, 3): all values are HPointer-encoded i64.
The mask is `(1ULL << count) - 1` (all bits set).

---

## Step-by-Step Plan

### Step 1: Add `StackRootRange` to `RootSet`

**File: `runtime/src/allocator/RootSet.hpp`**

Add to class (public):
```cpp
/// A contiguous range of stack-allocated i64 values that may contain HPointers.
/// hpointer_mask is MANDATORY for correctness on mixed arrays:
///   - Bit i set → base[i] is treated as HPointer root.
///   - Bit i clear → base[i] is ignored by the GC, even if it happens to be
///     numerically inside the heap / nursery address ranges.
/// For all-boxed arrays, hpointer_mask is simply ((1ULL << count) - 1).
struct StackRootRange {
    HPointer* base;
    size_t    count;
    uint64_t  hpointer_mask;
};
```

Add public methods (mirroring existing `stackRootPoint`/`restoreStackRootPoint`):
```cpp
// ===== Stack root ranges (temporary, frame-based) =====

size_t stackRangePoint() const { return stack_root_ranges.size(); }

void pushStackRootRange(HPointer* base, size_t count, uint64_t hpointer_mask) {
    if (base && count > 0) {
        stack_root_ranges.push_back(StackRootRange{base, count, hpointer_mask});
    }
}

void restoreStackRangePoint(size_t point) {
    if (point <= stack_root_ranges.size()) {
        stack_root_ranges.resize(point);
    }
}

const std::vector<StackRootRange>& getStackRootRanges() const {
    return stack_root_ranges;
}
```

Add private member:
```cpp
std::vector<StackRootRange> stack_root_ranges;
```

**File: `runtime/src/allocator/RootSet.cpp`**

- Add `stack_root_ranges.clear()` to `reset()`.

### Step 2: Scan `StackRootRanges` in Minor GC

**File: `runtime/src/allocator/NurserySpace.cpp` (~line 423, after Phase 1c)**

Insert Phase 1e between JIT roots (Phase 1c) and external scanners (Phase 1d):

```cpp
// Phase 1e: Stack root ranges (alloca-backed args arrays from compiled code).
// Only slots with hpointer_mask bit set are treated as roots. This is
// REQUIRED for correctness on mixed arrays: raw i64 values can fall into
// heap/nursery ranges by chance and must not be misinterpreted as pointers.
for (const auto &range : root_set.getStackRootRanges()) {
    HPointer *base = range.base;
    uint64_t mask  = range.hpointer_mask;

    for (size_t i = 0; i < range.count; ++i) {
        if (mask & (1ULL << i)) {
            evacuate(base[i], oldgen, &promoted_objects);
        }
    }
}
```

Notes:
- For all-boxed arrays, `mask` is all 1s up to `count`, so this is equivalent
  to scanning every slot.
- `evacuate`'s own `isInNursery` checks remain intact; they now only see
  bona-fide candidate pointer slots.

### Step 3: Include `StackRootRanges` in Major GC Root Collection

**File: `runtime/src/allocator/ThreadLocalHeap.cpp` (~line 273, in `collectRoots()`)**

After inserting `stack_roots`, expand ranges:
```cpp
// Stack root ranges (alloca-backed args arrays).
// Only slots whose hpointer_mask bit is set are added as roots. This avoids
// ever treating arbitrary i64 values as candidate pointers.
for (const auto &range : nursery_.getRootSet().getStackRootRanges()) {
    HPointer *base = range.base;
    uint64_t mask  = range.hpointer_mask;

    for (size_t i = 0; i < range.count; ++i) {
        if (mask & (1ULL << i)) {
            all_roots.insert(&base[i]);
        }
    }
}
```

`OldGenSpace::startMark()` remains unchanged; it still checks `isInHeap(obj)`
before pushing onto the mark stack. The mask ensures that raw `i64`s from
unboxed slots are never inserted into `all_roots` in the first place.

### Step 4: Add C ABI Functions

**File: `runtime/src/allocator/RuntimeExports.h`**

Declare under the "GC Interface" section (after `eco_gc_jit_root_count`):
```c
/// Stack root range management for compiled code.
///
/// Usage pattern in compiled LLVM IR:
///   %saved = call i64 @eco_gc_stack_range_point()
///   call void @eco_gc_push_stack_range(ptr %args, i64 %count, i64 %mask)
///   ... populate array, call runtime functions ...
///   call void @eco_gc_restore_stack_range_point(i64 %saved)
size_t   eco_gc_stack_range_point();

/// eco_gc_push_stack_range:
///   - base: pointer to an array of i64 slots on the stack
///   - count: number of slots
///   - hpointer_mask: bit i set → base[i] is a GC-managed HPointer root.
///     Bits MUST be accurate for mixed arrays; the GC only scans masked slots.
void     eco_gc_push_stack_range(uint64_t* base, size_t count, uint64_t hpointer_mask);

void     eco_gc_restore_stack_range_point(size_t point);
```

**File: `runtime/src/allocator/RuntimeExports.cpp`**

Implement using `Allocator::instance().getRootSet()` (same pattern as
`eco_gc_add_root` at ~line 2176):

```cpp
extern "C" size_t eco_gc_stack_range_point() {
    return Allocator::instance().getRootSet().stackRangePoint();
}

extern "C" void eco_gc_push_stack_range(uint64_t* base, size_t count, uint64_t hpointer_mask) {
    if (!base || count == 0) return;
    assert(count <= 64 && "stack root range exceeds 64-slot limit");
    Allocator::instance().getRootSet().pushStackRootRange(
        reinterpret_cast<HPointer*>(base), count, hpointer_mask);
}

extern "C" void eco_gc_restore_stack_range_point(size_t point) {
    Allocator::instance().getRootSet().restoreStackRangePoint(point);
}
```

### Step 5: Declare Runtime Functions in EcoToLLVM Module

**File: `runtime/src/codegen/Passes/EcoToLLVMInternal.h`**

Declare in `class EcoRuntime` (public section, alongside existing `getOrCreate*`):
```cpp
LLVM::LLVMFuncOp getOrCreateGcStackRangePoint(OpBuilder &builder) const;
LLVM::LLVMFuncOp getOrCreateGcPushStackRange(OpBuilder &builder) const;
LLVM::LLVMFuncOp getOrCreateGcRestoreStackRangePoint(OpBuilder &builder) const;
```

**File: `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp`**

Implement using `getOrCreateFunc` (same pattern as existing runtime function
declarations at ~line 337):

```cpp
LLVM::LLVMFuncOp EcoRuntime::getOrCreateGcStackRangePoint(OpBuilder &builder) const {
    auto i64Ty = IntegerType::get(builder.getContext(), 64);
    auto funcTy = LLVM::LLVMFunctionType::get(i64Ty, {});
    return getOrCreateFunc(builder, "eco_gc_stack_range_point", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGcPushStackRange(OpBuilder &builder) const {
    auto *ctx = builder.getContext();
    auto ptrTy = LLVM::LLVMPointerType::get(ctx);
    auto i64Ty = IntegerType::get(ctx, 64);
    auto voidTy = LLVM::LLVMVoidType::get(ctx);
    auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {ptrTy, i64Ty, i64Ty});
    return getOrCreateFunc(builder, "eco_gc_push_stack_range", funcTy);
}

LLVM::LLVMFuncOp EcoRuntime::getOrCreateGcRestoreStackRangePoint(OpBuilder &builder) const {
    auto i64Ty = IntegerType::get(builder.getContext(), 64);
    auto voidTy = LLVM::LLVMVoidType::get(builder.getContext());
    auto funcTy = LLVM::LLVMFunctionType::get(voidTy, {i64Ty});
    return getOrCreateFunc(builder, "eco_gc_restore_stack_range_point", funcTy);
}
```

### Step 6: Instrument Args-Array Call Sites in EcoToLLVMClosures.cpp

For each call site, apply this sequence around the existing code:

```
1. Create alloca (existing)
2. NEW: Zero-initialize via llvm.memset (count * 8 bytes → 0)
3. NEW: %saved = call @eco_gc_stack_range_point()
4. NEW: call @eco_gc_push_stack_range(%alloca, count, mask)
5. Populate the array (existing boxing + store loop)
6. Call the runtime function (existing)
7. NEW: call @eco_gc_restore_stack_range_point(%saved)
8. Continue with result (existing)
```

**Mask values per site:**

For mixed arrays (sites 1-typed and 4), `hpointer_mask` must be computed
correctly; the GC will only treat masked slots as roots. For all-boxed arrays,
the mask is all 1s up to `count`.

| Site | Mask | Rationale |
|------|------|-----------|
| 1: `typedArgsArray` | `~adjustedBitmap & ((1ULL << count) - 1)` | Mixed: only these slots are GC roots |
| 1: `boxedArgsArray` | `(1ULL << count) - 1` | All slots are HPointer roots |
| 2: `argsArray` | `(1ULL << count) - 1` | All boxed |
| 3: `newArgsArray` | `(1ULL << count) - 1` | All boxed |
| 4: `argsArray` | `~newargsBitmap & ((1ULL << count) - 1)` | Mixed: only these slots are GC roots |

**Segmentation-unknown (site 1) has TWO arrays** — both need registration.
Push both ranges before the first population loop; restore after the runtime call.

**Overflow guard (count > 64):** In the lowering, if `numNewArgs > 64`:
- Fall back to pushing each HPointer slot individually as a `stack_root`
  (using the existing `pushStackRoot` mechanism via `eco_gc_add_root` or a
  similar per-slot C ABI call).
- In practice this path will never fire (Elm arities < 10).

### Step 7: Create Helper Function

**File: `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`**

Extract a static helper to emit the zero-init + push + restore bracket:

```cpp
/// Emits the GC root range bracket around an args-array runtime call.
///
/// Before calling: the alloca must already exist, the population loop
/// has NOT yet started.
///
/// Returns {savedRangeDepth} so the caller can restore after the runtime call.
static Value emitPushArgsRootRange(
    ConversionPatternRewriter &rewriter, Location loc,
    const EcoRuntime &runtime,
    Value argsArray, int64_t numSlots, uint64_t hpointerMask);

/// Restores the GC root range stack after the runtime call.
static void emitRestoreArgsRootRange(
    ConversionPatternRewriter &rewriter, Location loc,
    const EcoRuntime &runtime,
    Value savedRangeDepth);
```

`emitPushArgsRootRange` does:
1. `llvm.memset(argsArray, 0, numSlots * 8, /*isVolatile=*/false)`
2. `%saved = call @eco_gc_stack_range_point()`
3. `call @eco_gc_push_stack_range(argsArray, numSlots, hpointerMask)`
4. Returns `%saved`

`emitRestoreArgsRootRange` does:
1. `call @eco_gc_restore_stack_range_point(%saved)`

Usage at each call site:
```cpp
Value argsArray = rewriter.create<LLVM::AllocaOp>(...);
Value saved = emitPushArgsRootRange(rewriter, loc, runtime, argsArray, numArgs, mask);
// ... existing population loop ...
// ... existing runtime call ...
emitRestoreArgsRootRange(rewriter, loc, runtime, saved);
```

### Step 8: Tests

1. **C++ unit test** (`runtime/test/`):
   - Allocate a stack array of HPointers (e.g., 3 elements)
   - Fill with freshly allocated heap objects
   - Register as root range via `pushStackRootRange`
   - Force minor GC (allocate enough to trigger nursery collection)
   - Assert each `args[i]` still resolves to a valid object with correct tag
   - Verify the objects were evacuated (addresses changed) but the root
     range slots were updated

2. **E2E regression test**:
   - Re-run the bootstrap scenario (Stage 7 native self-compile) that
     produced `eco_pap_extend: new_n_values (34) exceeds max_values (1)`
   - Confirm it passes

3. **GC stress test**:
   - Compile an Elm program with closure over-saturation (e.g., a function
     applied with more args than its arity, forcing `eco_apply_closure` to
     chain calls)
   - Set nursery size small to force frequent GC during the runtime calls
   - Assert correct results

---

## Files to Modify

| File | Changes |
|------|---------|
| `runtime/src/allocator/RootSet.hpp` | Add `StackRootRange` struct, new methods, private member |
| `runtime/src/allocator/RootSet.cpp` | Update `reset()` to clear `stack_root_ranges` |
| `runtime/src/allocator/NurserySpace.cpp` | Add Phase 1e range scanning in `minorGC()` |
| `runtime/src/allocator/ThreadLocalHeap.cpp` | Expand ranges in `collectRoots()` |
| `runtime/src/allocator/RuntimeExports.h` | Declare 3 new C ABI functions |
| `runtime/src/allocator/RuntimeExports.cpp` | Implement 3 new C ABI functions |
| `runtime/src/codegen/Passes/EcoToLLVMInternal.h` | Declare 3 new `getOrCreate*` methods |
| `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp` | Implement 3 new `getOrCreate*` methods |
| `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp` | Instrument 4 call sites, add 2 helpers |

## Files NOT Modified

| File | Reason |
|------|--------|
| `OldGenSpace.cpp` | `startMark()` receives roots from `collectRoots()` — ranges expanded there; `isInHeap` check already guards marking |
| `EcoToLLVM.cpp` | Main pass entry — no changes needed |
| `EcoToLLVMHeap.cpp` | Allocation ops — unrelated |
