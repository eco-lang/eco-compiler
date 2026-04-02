# Migrate to LLVM's RewriteStatepointsForGC Pass

## Status: READY FOR IMPLEMENTATION
## Priority: High (blocks native bootstrap — current nop-safepoint approach is fundamentally broken)

---

## Goal

Replace our manual `gc.statepoint` + `gc.relocate` emission with LLVM's built-in `RewriteStatepointsForGC` pass, and critically, wrap the **actual allocating/calling functions** in statepoints rather than a separate nop callee.

## Why — Three Compounding Problems

### Problem 1: Nop safepoint callee records stack maps at the wrong address

Our current approach emits `gc.statepoint(@__eco_gc_safepoint_nop)` as a separate instruction before each allocating call. The stack map records liveness at the nop call's return address. But GC triggers inside the actual allocation calls (`eco_alloc_*`, kernel calls, `eco_apply_*`), not at the nop. When the GC walks the stack, the return address it finds is from the allocation call — which has no stack map entry. The live root information is recorded at the wrong program point.

This is why the Stage 7 native compiler crashes with `Pointer above heap end` — the GC runs during an allocation, tries to find stack roots, can't find a stack map for the actual call's return address, and either misses roots or processes stale data.

### Problem 2: Optimizer reorders gc.relocate past other statepoints

LLVM's optimizer can move a `gc.relocate` from statepoint S1 past statepoint S2 in the same basic block (no data dependency prevents this). SelectionDAG asserts that all relocates from S1 are visited before S2 begins. We added a post-optimization reordering pass as a workaround, but this is fragile.

### Problem 3: Reimplementing LLVM's logic poorly

We manually compute liveness, emit gc.relocate, rewrite SSA uses, clean up dead relocates, and reorder misplaced relocates. `RewriteStatepointsForGC` does all of this correctly, integrated with the optimization pipeline.

## Current Architecture

```
Elm compiler
    → eco.safepoint ops (explicit liveness in MLIR)
    ↓
SafepointOpLowering (MLIR → LLVM dialect)
    → __eco_safepoint_marker(inttoptr %val, ...) calls
    ↓
convertSafepointMarkers (LLVM IR pass)
    → gc.statepoint(@__eco_gc_safepoint_nop) + gc.relocate + SSA rewrite
    ↓
LLVM optimization
    → may reorder gc.relocate (workaround: post-opt reordering pass)
    ↓
removeDeadGCRelocates (workaround: clean up dead relocates)
    ↓
SelectionDAG codegen
    → stack map entries point to nop call return addresses (WRONG!)
    ↓
Runtime GC walks stack
    → can't find roots at actual allocation return addresses → crash
```

## Target Architecture

```
Elm compiler
    → eco.safepoint ops REMOVED (or kept only for MLIR-level validation)
    ↓
Standard MLIR → LLVM IR translation
    → Regular calls to eco_alloc_*, kernel functions, eco_apply_*, etc.
    → All functions have gc "statepoint-example" attribute (already present)
    ↓
RewriteStatepointsForGC (LLVM pass, runs late in optimization pipeline)
    → Computes liveness automatically at each call site
    → Wraps each call in gc.statepoint with correct gc-live bundle
    → Inserts gc.relocate with correct ordering
    → Rewrites SSA uses of relocated pointers
    ↓
SelectionDAG codegen
    → stack map entries point to ACTUAL call return addresses (CORRECT!)
    ↓
Runtime GC walks stack
    → finds stack map entries at allocation return addresses → correct roots
```

## Steps

### Step 1: Verify RewriteStatepointsForGC works with our IR

Create a small test: a function with `gc "statepoint-example"` that makes regular calls (no manual statepoints), and run `RewriteStatepointsForGC` on it. Verify:
- The pass wraps calls in `gc.statepoint`
- `gc.relocate` is inserted for `ptr addrspace(1)` values
- Our `i64` HPointers that pass through `inttoptr`/`ptrtoint` are handled (the pass may need all GC pointers to be typed as `ptr addrspace(1)` throughout, not `i64`)

If the pass doesn't recognize `i64` values as GC roots (likely), we need Step 1b.

### Step 1b: Evaluate HPointer representation change

`RewriteStatepointsForGC` identifies GC pointers by type (`ptr addrspace(1)`). Our HPointers are `i64` with `inttoptr`/`ptrtoint` at boundaries. Options:
- **Option A**: Keep `i64` representation, add `inttoptr` before each call and `ptrtoint` after. The pass should see the `ptr addrspace(1)` values at call boundaries.
- **Option B**: Change the core representation to `ptr addrspace(1)` throughout the LLVM IR. This is cleaner but requires changes to the Eco MLIR dialect lowering.
- **Option C**: Use the pass's `gc-live` bundle hints if available, or a custom GC strategy that teaches it about i64 roots.

Evaluate which option has the smallest blast radius.

### Step 2: Remove SafepointOpLowering and eco.safepoint emission

Since `RewriteStatepointsForGC` computes liveness automatically:
- Remove `emitSafepoint` calls from Elm compiler (Expr.elm, Functions.elm, Patterns.elm)
- Remove `SafepointOpLowering` from the MLIR pass pipeline
- Remove the `eco.safepoint` op definition (or keep for future MLIR-level validation)
- Remove `liveEcoValueVars`, `definedSsaVars` tracking from Context.elm

This dramatically simplifies the Elm compiler codegen — no more safepoint insertion, no more scoping bugs.

### Step 3: Integrate RewriteStatepointsForGC into the pipeline

Add the pass to:
- `eco-boot.cpp` (AOT native compiler) — after optimization, before codegen
- `ecoc.cpp` (AOT + JIT paths)
- `EcoRunner.cpp` (test JIT)

Use `llvm::createRewriteStatepointsForGCLegacyPass()` for the legacy pass manager, or the new pass manager equivalent.

### Step 4: Remove StatepointConversion.cpp

Once the pass handles everything:
- Remove `convertSafepointMarkers`
- Remove `removeDeadGCRelocates`
- Remove the relocate reordering workaround
- Remove `__eco_safepoint_marker` / `__eco_gc_safepoint_nop`
- The entire `StatepointConversion.cpp` / `.h` can be deleted

### Step 5: Verify stack map compatibility

The pass generates standard LLVM stack maps. Verify that `ThreadLocalHeap::collectStackRootsFromStackMap` and `StackMap.cpp` correctly parse the new stack map format. Key checks:
- Stack map record format matches what `StackMapParser` expects
- Return addresses in the stack map correspond to actual call sites (not nop calls)
- Location kinds (Indirect with RBP offset) match what the stack walker handles
- The stack root pointers extracted are valid HPointers

### Step 6: End-to-end testing

- E2E tests pass (ecoc JIT path)
- Bootstrap Stage 6: native ELF compiles without assertion failures
- Bootstrap Stage 7: native compiler runs without heap assertion crashes
- Bootstrap Stage 8: native fixed-point verification passes
- GC stress tests: programs that allocate heavily across calls don't crash

## Risks

- `RewriteStatepointsForGC` may not handle our `i64` ↔ `ptr addrspace(1)` representation without changes
- The pass wraps ALL calls in statepoints, including calls that can't trigger GC (e.g., pure arithmetic helpers). This increases stack map size and may have performance impact. Can mitigate by marking non-GC-triggering functions with `gc-leaf-function` attribute.
- The pass may interact badly with our existing LLVM optimization pipeline ordering
- Stack map format differences between our manual statepoints and the pass's output

## What Can Be Removed After Migration

- `StatepointConversion.cpp` / `.h` (entire file)
- `SafepointOpLowering` in `EcoToLLVMErrorDebug.cpp`
- `eco.safepoint` op in the Eco MLIR dialect
- `emitSafepoint` in `Expr.elm`
- `liveEcoValueVars`, `definedSsaVars` in `Context.elm`
- All the safepoint insertion code in `Expr.elm`, `Functions.elm`, `Patterns.elm`
- The `generateGenericCloneFunc` / `generateMainEntry` / `generateManagerLeaf` scope resets we added
- The `generateLet` varMappings cleanup (Option A fix)
- The `generateNode` / `processLambdas` post-function scope resets

This is a significant simplification of the Elm compiler's MLIR codegen.

---

## Spike Results: RewriteStatepointsForGC Compatibility

Tested with LLVM 21's `opt -passes="rewrite-statepoints-for-gc"` on four patterns:

| Pattern | Input | gc-live? | gc.relocate? | SSA rewrite? | Verdict |
|---------|-------|----------|-------------|-------------|---------|
| Pure i64 HPointers | `i64 %x` args, `i64` returns | NO | NO | NO | **Invisible** — pass ignores i64 values entirely |
| Pure ptr addrspace(1) | `ptr addrspace(1)` throughout | YES | YES | YES | **Perfect** — full automatic statepoint insertion |
| Mixed i64 + inttoptr at boundaries | `inttoptr i64 %x to ptr addrspace(1)` before calls | Partial | Partial | **BROKEN** — second `inttoptr` from stale i64 after relocation | **Unsafe** |
| Future zero-based addrspace(1) | `ptr addrspace(1)` with stores/loads | YES | YES | YES | **Perfect** — exactly what the pass expects |

**Conclusion:** The pass requires `ptr addrspace(1)` throughout. The current `i64` representation is invisible to it. A mixed approach doesn't work because `ptrtoint` breaks the relocation chain.

---

## Prerequisite: HPointer Representation Change to ptr addrspace(1)

The migration to `RewriteStatepointsForGC` requires changing the HPointer representation from `i64` (40-bit offset, left-shift-by-3) to `ptr addrspace(1)` (zero-based, 8-byte aligned). This is a cross-cutting change.

### Future HPointer Design

- **Type**: `ptr addrspace(1)` (LLVM GC-tracked pointer)
- **Alignment**: 8-byte aligned (no shift needed)
- **Zero-based**: Offset from heap base = 0 (virtual memory mapping)
- **Constants**: Bottom 3 bits encode embedded constants (Unit, True, False, Nil, etc.) — valid because all real heap objects are 8-byte aligned, so bottom 3 bits are always 0 for real pointers
- **Compatibility**: `RewriteStatepointsForGC` tracks `ptr addrspace(1)` values automatically. Bottom-3-bit encoding is invisible to the pass (it doesn't inspect pointer values)

### HPointer Change Impact Assessment

#### C++ Runtime — Allocator Core

| File | Location | Current Code | Change | Complexity |
|------|----------|-------------|--------|------------|
| Heap.hpp:112-118 | `HPointer` struct | 40-bit ptr + 4-bit constant + 20-bit padding | Replace with `void*` or `uintptr_t`; constants in bottom 3 bits | Medium |
| Heap.hpp:122-128 | `Unboxable` union | `HPointer p; i64 i; f64 f; u16 c` | Change `p` to raw pointer type | Low |
| Allocator.hpp:187-192 | `fromPointerRaw()` | `ptr.ptr << 3` + heap_base | Remove shift; pointer is direct | Low |
| Allocator.hpp:196-204 | `toPointerRaw()` | `(obj - heap_base) >> 3` | Remove shift; pointer = obj address | Low |
| Allocator.cpp:364-385 | `resolve()` | Follow forwarding + `<< 3` | Remove shift in forwarding chain | Low |
| Allocator.cpp:388-393 | `wrap()` | Validate + `>> 3` | Remove shift | Low |

#### C++ Runtime — GC Forwarding (NurserySpace + OldGenSpace)

| File | Location | Current Code | Change | Complexity |
|------|----------|-------------|--------|------------|
| NurserySpace.cpp:518 | Forward resolution | `fwd->header.forward_ptr << 3` | Remove shift | Low |
| NurserySpace.cpp:574 | Forward store | `byte_offset >> 3` | Remove shift | Low |
| NurserySpace.cpp:624 | Forward resolution | `fwd->header.forward_ptr << 3` | Remove shift | Low |
| NurserySpace.cpp:670 | Forward store | `byte_offset >> 3` | Remove shift | Low |
| NurserySpace.cpp:858 | Compact resolution | `fwd->header.forward_ptr << 3` | Remove shift | Low |
| NurserySpace.cpp:930 | Compact store | `(new_obj - heap_base) >> 3` | Remove shift | Low |
| OldGenSpace.cpp:35 | `readBarrier()` | `ptr.ptr << 3` | Remove shift | Low |
| OldGenSpace.cpp:937 | Forward encode | `(new_ptr - heap_base) >> 3` | Remove shift | Low |
| OldGenSpace.cpp:950 | Forward resolve | `fwd->header.forward_ptr << 3` | Remove shift | Low |
| Heap.hpp:258-266 | `Forward` struct | `forward_ptr : POINTER_BITS` (40-bit) | Widen to full pointer or keep as offset | Medium |

#### C++ Runtime — ABI Boundary (RuntimeExports.cpp)

| File | Location | Current Code | Change | Complexity |
|------|----------|-------------|--------|------------|
| RuntimeExports.cpp:35-40 | `ptrToHPointer()` | `memcpy` HPointer → uint64_t | Becomes simple cast (ptr → uint64_t) or eliminated | Low |
| RuntimeExports.cpp:46-54 | `hpointerToPtr()` | Check constant field, call `resolve()` | Check bottom 3 bits for constants, otherwise deref directly | Low |
| RuntimeExports.cpp:357-409 | `eco_store_field()` Cons tail | Extract bits 0-39 and bits 40-43 | Store pointer directly; check bottom 3 bits for constants | Medium |
| RuntimeExports.cpp:595-602 | JIT constant detect | `(ptr >> 40) & 0xF` | `ptr & 0x7` for bottom 3 bits | Low |
| RuntimeExports.cpp:787-854 | `print_if_constant()` | `val & 0xFFFFFFFFFF`, `val >> 40` | `val & 0x7` for constant check | Low |
| RuntimeExports.cpp (50+ locs) | All `eco_alloc_*` functions | Return `uint64_t` (HPointer) | Return `void*` or `uintptr_t` (addrspace(1) ptr) | Medium — mechanical but many sites |

#### C++ Runtime — Kernel Functions

| File | Location | Current Code | Change | Complexity |
|------|----------|-------------|--------|------------|
| elm-kernel-cpp KernelExports.h | All kernel function sigs | `uint64_t` params/returns for HPointers | Change to `void*` or pointer type | Medium — ~100 function signatures |
| eco-kernel-cpp KernelExports.h | All kernel function sigs | `uint64_t` params/returns for HPointers | Same as above | Medium — ~50 function signatures |

#### MLIR Lowering — Type Conversion

| File | Location | Current Code | Change | Complexity |
|------|----------|-------------|--------|------------|
| EcoToLLVMRuntime.cpp:28-34 | Type converter | `eco::ValueType → i64` | `eco::ValueType → ptr addrspace(1)` | **Critical** — single line, global effect |
| EcoToLLVMInternal.h:40-67 | Constant encoding | `kind << 40` (constants in bits 40-43) | `kind & 0x7` (constants in bottom 3 bits) | Medium |
| EcoToLLVMTypes.cpp:23-42 | ConstantOpLowering | `ConstantOp(i64, encoded)` | `IntToPtrOp(addrspace(1), encoded)` or `ConstantOp(ptr, encoded)` | Medium |
| EcoToLLVMTypes.cpp:48-125 | StringLiteralOp | Returns i64 from alloc call | Returns ptr addrspace(1) | Low |

#### MLIR Lowering — Heap Operations

| File | Location | Current Code | Change | Complexity |
|------|----------|-------------|--------|------------|
| EcoToLLVMHeap.cpp:75-120 | UnboxOpLowering | i64 → `eco_resolve_hptr()` → raw ptr → GEP → load | ptr addrspace(1) → GEP → load (no resolve) | Medium — simplification |
| EcoToLLVMHeap.cpp:22-69 | BoxOpLowering | alloc() returns i64 | alloc() returns ptr addrspace(1) | Low |
| EcoToLLVMRuntime.cpp:92-160 | Allocation function decls | All return `I64_TY` | All return `PointerType::get(ctx, 1)` | Medium — ~12 declarations |
| EcoToLLVMRuntime.cpp:166-276 | Field/utility function decls | `i64` for HPointer params | `ptr addrspace(1)` for HPointer params | Medium — ~15 declarations |

#### MLIR Lowering — Closures

| File | Location | Current Code | Change | Complexity |
|------|----------|-------------|--------|------------|
| EcoToLLVMClosures.cpp:26-81 | ProjectClosureOp | `IntToPtrOp(i64 → ptr)` for unboxed ptrs | Direct ptr addrspace(1) | Medium |
| EcoToLLVMClosures.cpp:144-532 | Closure wrappers | Many `inttoptr`/`ptrtoint` conversions (~20 sites) | Eliminate most conversions | High — most complex file |
| EcoToLLVMClosures.cpp:260-320 | Wrapper arg loading | Load i64, resolve, convert | Load ptr addrspace(1) directly | Medium |

#### MLIR Lowering — Safepoint/Statepoint (removed by this migration)

| File | Location | Current Code | Change | Complexity |
|------|----------|-------------|--------|------------|
| EcoToLLVMErrorDebug.cpp:56-101 | SafepointOpLowering | `IntToPtrOp(i64 → ptr addrspace(1))` | **Deleted** — RewriteStatepointsForGC handles this | N/A |
| StatepointConversion.cpp | Entire file | Manual gc.statepoint + gc.relocate | **Deleted** | N/A |
| EcoToLLVMErrorDebug.cpp:146 | DbgOpLowering assertion | `assert(arg.getType().isInteger(64))` | `assert(arg.getType() == ptr addrspace(1))` | Low |

#### Elm Compiler (MLIR codegen)

| File | Location | Current Code | Change | Complexity |
|------|----------|-------------|--------|------------|
| Types.elm:73-77 | `ecoValue` | `NamedStruct "eco.value"` | No change (MLIR type stays same; lowering changes) | None |
| Expr.elm (25+ sites) | `emitSafepoint` calls | Safepoint before calls/papExtend | **Deleted** — pass handles liveness automatically | N/A |
| Functions.elm | Scope resets | `definedSsaVars`/`varMappings` cleanup | **Deleted** — no more safepoint scoping | N/A |
| Context.elm | `liveEcoValueVars` | SSA var tracking for safepoints | **Deleted** | N/A |

### Summary Counts

| Category | Sites to Change | Complexity |
|----------|----------------|------------|
| Remove shift operations (C++ `<< 3` / `>> 3`) | 12 | Low |
| Change constant encoding (bits 40-43 → bottom 3 bits) | 6 | Medium |
| Change allocation function signatures (C++) | ~60 | Medium (mechanical) |
| Change kernel function signatures (C++) | ~150 | Medium (mechanical) |
| Change MLIR lowering type converter | 1 (global effect) | **Critical** |
| Change MLIR allocation/utility decls | ~27 | Medium |
| Simplify closure lowering | ~20 inttoptr/ptrtoint sites | High |
| Delete safepoint infrastructure | ~15 files/functions | N/A (deletion) |
| Change Forward pointer struct | 1 | Medium |

**Total estimated change sites: ~290, of which ~200 are mechanical signature changes.**
