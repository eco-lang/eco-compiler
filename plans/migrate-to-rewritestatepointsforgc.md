# Migrate to LLVM RewriteStatepointsForGC (RS4GC)

## Status: READY FOR IMPLEMENTATION
## Priority: High
## Prerequisite complete: `!eco.value -> ptr addrspace(1)` is done and tested

---

## Goal

Replace Eco's custom `StatepointConversion.cpp` / `__eco_safepoint_marker` pipeline
with LLVM's upstream `RewriteStatepointsForGC` pass. RS4GC can now identify GC pointers
by type because `!eco.value` lowers to `ptr addrspace(1)`.

---

## Current Pipeline (to be replaced)

```
Eco IR
  -> EcoGCPrepare (computes liveness, attaches roots as operands on alloc/call ops)
  -> EcoToLLVM lowering:
       SafepointOpLowering: eco.safepoint -> __eco_safepoint_marker + __eco_safepoint_poll
       emitAllocWithSafepoint: __eco_safepoint_marker before alloc calls
       emitSafepointMarker: __eco_safepoint_marker before call-like ops (~20 sites in Closures)
       emitWrapperSafepointMarker: __eco_safepoint_marker in closure wrappers (~8 sites)
       EcoToLLVMHeap slow-path: inline __eco_safepoint_marker before region_slow
       EcoToLLVM.cpp:356: sets gc "statepoint-example" on all non-external functions
  -> MLIR-to-LLVM translation
  -> StatepointConversion::convertSafepointMarkers()   [ecoc.cpp, eco-boot.cpp, EcoRunner.cpp]
       Finds each __eco_safepoint_marker, locates next call, wraps in gc.statepoint
       Emits gc.relocate, rewrites roots via alloca/mem2reg (PromoteMemToReg)
  -> LLVM optimization passes (base transformer)
  -> StatepointConversion::removeDeadGCRelocates()
  -> Backend emits stackmaps
```

## Target Pipeline (RS4GC)

```
Eco IR
  -> EcoGCPrepare (unchanged initially — extra operands are harmless to RS4GC)
  -> EcoToLLVM lowering:
       eco.safepoint erased (no-op)
       No __eco_safepoint_marker emission anywhere
       Functions get gc "eco-gc" attribute
  -> MLIR-to-LLVM translation
  -> RewriteStatepointsForGC (runs in transformer callback before opt passes)
       Identifies all calls in gc "eco-gc" functions (skipping gc-leaf-function)
       Computes liveness of ptr addrspace(1) values via backward dataflow (INV-5/6)
       Wraps calls in gc.statepoint, emits gc.relocate, alloca/mem2reg (INV-12-18)
  -> LLVM optimization passes
  -> Backend emits stackmaps
```

---

## Implementation Steps

### Step 1: Create EcoGCStrategy in LLVM fork

**New file:** `llvm/lib/CodeGen/EcoGCStrategy.cpp` (in the LLVM fork, not in /work)

Create a `GCStrategy` subclass registered as `"eco-gc"`:
- `UseStatepoints = true` (drives RS4GC)
- `isGCManagedPointer()` returns true for `ptr addrspace(1)` (INV-1)
- `shouldRewriteStatepointsIn()` returns true except for `gc-leaf-function` fns

Add to LLVM's CMake so the registry entry links into `opt`/the backend.

**Validation:** Hand-craft a small LLVM IR file with `gc "eco-gc"` functions and
`ptr addrspace(1)` values, run RS4GC via `opt`, verify gc.statepoint/gc.relocate
appear correctly.

---

### Step 2: Switch GC attribute name to "eco-gc"

**File:** `runtime/src/codegen/Passes/EcoToLLVM.cpp:356`

Change:
```cpp
func.setGarbageCollector("statepoint-example");
```
to:
```cpp
func.setGarbageCollector("eco-gc");
```

**Validation:** Build and run tests — behavior unchanged because StatepointConversion
is still in place and doesn't inspect the GC name.

---

### Step 3: Mark leaf runtime functions with `gc-leaf-function`

**File:** `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp`

For every `getOrCreate*()` method, add `gc-leaf-function` to functions that never
allocate or trigger GC.

**Must NOT be gc-leaf-function** (can trigger GC):
- `eco_alloc_*` (non-fast, non-slow base variants — `EcoToLLVMRuntime.cpp:91-211`)
- `eco_alloc_*_slow` (always may GC)
- `eco_gc_alloc_region_slow`
- `eco_apply_closure` (may allocate internally)
- `eco_pap_extend` (may allocate)
- `eco_closure_call_saturated` (may allocate)
- `eco_apply_segmentation_unknown` (may allocate)
- `eco_clone_array` (allocates a new ElmArray)
- `eco_minor_gc`, `eco_major_gc`
- `__eco_safepoint_poll` (triggers collection)

**Should be gc-leaf-function** (never trigger GC):
- `eco_alloc_*_fast` (return nullptr on failure, never GC)
- `eco_gc_alloc_region_fast`
- All `eco_store_field*`, `eco_store_record_field*`, `eco_set_unboxed`
- All `eco_init_*_at` (init at pointer, no allocation)
- `eco_gc_add_root`, `eco_gc_remove_root`, `eco_gc_jit_root_count`
- `eco_gc_stack_range_point`, `eco_gc_push_stack_range`, `eco_gc_restore_stack_range_point`
- `eco_get_tag`, `eco_get_header_tag`, `eco_get_custom_ctor`
- `eco_cons_head_i64`, `eco_cons_head_f64`, `eco_cons_head_i16`
- `eco_int_pow`, `eco_resolve_hptr`
- `eco_dbg_print*`, `eco_crash`
- `eco_register_type_graph`
- All `Elm_Kernel_Basics_*` math functions
- ~~`eco_clone_array`~~ — **NOT leaf**, allocates (see Q2 resolved)

Implementation — after creating each leaf FuncOp, set via `passthrough` attribute
(MLIR LLVM dialect convention, confirmed in Q4):
```cpp
// If func already has passthrough attrs, append to the existing array.
SmallVector<Attribute> attrs;
if (auto existing = func->getAttrOfType<ArrayAttr>("passthrough"))
    attrs.append(existing.begin(), existing.end());
attrs.push_back(builder.getStringAttr("gc-leaf-function"));
func->setAttr("passthrough", builder.getArrayAttr(attrs));
```

**Validation:** Dump LLVM IR, verify attributes appear on the expected functions.

---

### Step 4: Stop emitting `__eco_safepoint_marker` calls

The marker is emitted in 5 locations across 4 files. All must be changed.

#### 4a: SafepointOpLowering (eco.safepoint -> erase)

**File:** `runtime/src/codegen/Passes/EcoToLLVMErrorDebug.cpp:54-117`

Replace entire `matchAndRewrite` body with:
```cpp
rewriter.eraseOp(op);
return success();
```

Remove `getOrCreateSafepointPoll()` helper (lines 36-52).

#### 4b: emitAllocWithSafepoint

**File:** `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:598-657`

Remove lines 627-651 (the marker emission block). Keep only the alloc call:
```cpp
auto allocCall = rewriter.create<LLVM::CallOp>(loc, allocFunc, args);
return allocCall.getResult();
```

#### 4c: emitSafepointMarker (call-like ops)

**File:** `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:663-709`

Make body a no-op (empty return for void, keep debug logging if needed).
Remove all ~20 call sites in `EcoToLLVMClosures.cpp` that call `emitSafepointMarker()`.

#### 4d: emitWrapperSafepointMarker (closure wrappers)

**File:** `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:715-745`

Make body a no-op. Remove all ~8 call sites in `EcoToLLVMClosures.cpp`.

#### 4e: Inline marker in EcoToLLVMHeap.cpp slow path

**File:** `runtime/src/codegen/Passes/EcoToLLVMHeap.cpp:1420-1433`

Remove the inline `__eco_safepoint_marker` emission block. The
`eco_gc_alloc_region_slow` call becomes a safepoint automatically via RS4GC.

#### 4f: Remove getOrCreateSafepointMarker

**File:** `runtime/src/codegen/Passes/EcoToLLVMRuntime.cpp:579-592` — delete method.
**File:** `runtime/src/codegen/Passes/EcoToLLVMInternal.h:~315` — delete declaration.

---

### Step 5: Wire RS4GC into pipeline, remove StatepointConversion

#### 5a: Replace StatepointConversion in driver transformers

All three drivers use a `transformer` callback on `llvm::Module*`:

**File:** `runtime/src/codegen/EcoRunner.cpp:~189-194`
**File:** `runtime/src/codegen/ecoc.cpp:~245-250` (plus `~189` in dumpLLVMIR)
**File:** `runtime/src/codegen/eco-boot.cpp:~586-612`

Current pattern in each:
```cpp
options.transformer = [baseTransformer](llvm::Module *m) -> llvm::Error {
    eco::convertSafepointMarkers(*m);
    assert(!m->getFunction("__eco_safepoint_marker") && ...);
    auto err = baseTransformer(m);
    if (err) return err;
    eco::removeDeadGCRelocates(*m);
    return llvm::Error::success();
};
```

Replace with (LLVM 21.1.4, legacy FunctionPassManager):
```cpp
#include "llvm/Transforms/Scalar/RewriteStatepointsForGC.h"
#include "llvm/IR/LegacyPassManager.h"

options.transformer = [baseTransformer](llvm::Module *m) -> llvm::Error {
    // Run RS4GC: inserts gc.statepoint/gc.relocate for all GC-triggering calls
    // in functions with gc "eco-gc", computing liveness automatically.
    llvm::legacy::FunctionPassManager FPM(m);
    FPM.add(llvm::createRewriteStatepointsForGCLegacyPass());
    FPM.doInitialization();
    for (auto &F : *m)
        if (!F.isDeclaration())
            FPM.run(F);
    FPM.doFinalization();

    auto err = baseTransformer(m);
    if (err) return err;
    return llvm::Error::success();
};
```

#### 5b: Remove StatepointConversion from build

**File:** `runtime/src/codegen/CMakeLists.txt:221`

Remove `Passes/StatepointConversion.cpp` from the source list.

#### 5c: Remove includes and dead code

Remove `#include "StatepointConversion.h"` from `ecoc.cpp`, `eco-boot.cpp`, `EcoRunner.cpp`.
Delete or archive `StatepointConversion.cpp` and `StatepointConversion.h`.

---

### Step 6: Clean up dead declarations

**File:** `runtime/src/codegen/RuntimeSymbols.cpp`
- Remove `__eco_safepoint_poll` from JIT symbol registration (if no longer called).

**File:** `runtime/src/codegen/Passes/EcoToLLVMInternal.h`
- Remove `emitAllocWithSafepoint`, `emitSafepointMarker`, `emitWrapperSafepointMarker`
  declarations (or leave as empty stubs if callers remain).

---

### Step 7: Validate

#### 7a: IR inspection
- Dump LLVM IR after RS4GC, verify:
  - gc.statepoint intrinsics at GC-triggering calls (alloc_slow, apply_closure, etc.)
  - NO gc.statepoint at gc-leaf-function calls (alloc_fast, store_field, math, etc.)
  - gc.relocate for all live `ptr addrspace(1)` values
  - No `__eco_safepoint_marker` references remain
  - Functions have `gc "eco-gc"` attribute

#### 7b: Stackmap validation
- No `Constant(0)` entries for live roots (the Stage 7 bug this fixes)
- Stackmap record counts comparable to or greater than before

#### 7c: Test suite
```bash
cmake --build build --target full
```
- Full E2E tests
- GC stress tests with deep recursion
- Long-running programs with repeated minor/major GC cycles
- Heavy closure allocation (papExtend paths)

---

## Step 8: Future Cleanup (separate PR)

- **EcoGCPrepare simplification:** Remove root-attachment logic for GCRootCarrier ops.
  RS4GC computes its own liveness; the extra operands on alloc/call/papExtend ops
  become dead weight. The GCRootCarrier interface can be removed.

- **eco.safepoint op removal:** Once EcoGCPrepare no longer populates it, remove
  from the Eco MLIR dialect definition.

- **Elm compiler safepoint codegen removal:** Delete `emitSafepoint` calls from
  `Expr.elm`, `Functions.elm`, `Patterns.elm`. Delete `liveEcoValueVars`,
  `definedSsaVars` tracking from `Context.elm`. Significant simplification.

- **Remove eco_safepoint / __eco_safepoint_poll from runtime:** Once no codegen
  path references them.

---

## Recommended Implementation Order

1. **Step 1** — LLVM fork: EcoGCStrategy + hand-test with opt
2. **Step 2** — GC attribute rename (safe, no behavior change)
3. **Step 3** — Mark leaf functions (safe, no behavior change with old pipeline)
4. **Step 5a** — Wire RS4GC alongside StatepointConversion (compare IR output)
5. **Step 4** — Stop emitting markers (cut over to RS4GC as sole statepoint source)
6. **Step 5b/5c** — Remove StatepointConversion from build
7. **Step 6** — Clean up dead declarations
8. **Step 7** — Full validation

---

## Resolved Questions

### Q1: Pass Manager — use legacy FunctionPassManager
MLIR side uses `mlir::PassManager` (new PM). LLVM IR side currently uses custom
post-translation passes (`StatepointConversion`) stitched into drivers. RS4GC should
be added as a legacy function pass via `createRewriteStatepointsForGCPass()` — least
invasive, works with the existing `llvm::Module*` transformer callbacks.

### Q2: eco_clone_array allocates — NOT gc-leaf
`eco_clone_array` allocates a new `ElmArray`. Must be treated as non-leaf / may-GC.

### Q3: Fast/slow split works correctly under RS4GC
RS4GC's alloca/mem2reg approach (INV-16/17/18) handles arbitrary control-flow merges:
creates one alloca per live GC pointer in the entry block, stores relocated values,
rewrites all uses to loads, then `PromoteMemToReg` synthesizes PHIs joining fast
(no-GC) and slow (GC + relocation) paths. No special handling needed.

### Q4: gc-leaf-function via passthrough attribute
MLIR LLVM dialect carries arbitrary LLVM function attributes via the `passthrough`
attribute on `LLVMFuncOp`. The translation to LLVM IR converts these to real
function attributes. Use:
```cpp
func->setAttr("passthrough",
    builder.getArrayAttr({builder.getStringAttr("gc-leaf-function")}));
```
Note: if the FuncOp already has a `passthrough` attr, append to the existing array.

### Q5: ECO_GC_DEBUG — no replacement needed for correctness
Losing `StatepointConversion`-specific debug output is acceptable. For diagnostics:
- Keep/extend `EcoGCLivenessAudit.cpp` for MLIR-level verification of root sets
- For RS4GC-level debug traces, add conditional logging in the LLVM fork's RS4GC
  (guarded by CMake option or env var)
No functional pipeline change required.

### Q6: Attribute stripping is safe for Eco
RS4GC strips `dereferenceable`, `noalias`, `readonly`, `nofree`, `llvm.invariant.start`.
Eco never relies on these for semantics — all GC/runtime invariants are expressed via
the heap model and invariants docs. Only effect: some LLVM optimizations may be
slightly weaker in GC functions. Acceptable.

### Q7: LLVM version is 21.1.4
LLVM 21.1.4. Opaque pointers are the default (no typed pointers). RS4GC API:
- Header: `llvm/Transforms/Scalar/RewriteStatepointsForGC.h`
- Legacy pass: `llvm::createRewriteStatepointsForGCLegacyPass()`
- New PM: `RewriteStatepointsForGCPass` (available but not needed)
- GCStrategy API uses opaque pointers with address spaces for classification.

### Q8: eco.safepoint becomes a pure no-op — drop __eco_safepoint_poll
`eco.safepoint` becomes a front-end marker erased at LLVM level. No
`__eco_safepoint_poll` call emitted. RS4GC wraps the real GC-triggering calls
(alloc_slow, apply_closure, etc.) as safepoints automatically.
If a cooperative/periodic polling scheme is needed later, re-introduce a poll
function (not marked gc-leaf) and emit calls to it; RS4GC will wrap them.

---

## Assumptions

1. The LLVM fork is maintained separately and can accept new files in `lib/CodeGen/`.
2. `ptr addrspace(1)` is consistently used for ALL GC-managed pointers in LLVM IR
   after EcoToLLVM lowering — no `i64` HPointers remain at call boundaries.
3. Stackmap format and runtime parsing (`StackMap.cpp:v3`, `collectStackRootsFromStackMap`)
   are compatible with RS4GC's gc.statepoint output (same backend machinery).
4. RS4GC's more complete liveness (INV-5/6/7) produces a superset of roots that
   StatepointConversion tracks — no regressions in root coverage.
5. EcoGCPrepare and eco.safepoint can remain during migration without interference.

---

## Files Modified (summary)

| File | Change | Step |
|------|--------|------|
| `llvm/.../EcoGCStrategy.cpp` (NEW) | GCStrategy subclass for eco-gc | 1 |
| `Passes/EcoToLLVM.cpp:356` | `"statepoint-example"` -> `"eco-gc"` | 2 |
| `Passes/EcoToLLVMRuntime.cpp` (many getOrCreate*) | Add gc-leaf-function attrs | 3 |
| `Passes/EcoToLLVMErrorDebug.cpp:54-117` | SafepointOpLowering -> erase op | 4a |
| `Passes/EcoToLLVMRuntime.cpp:598-657` | Remove marker from emitAllocWithSafepoint | 4b |
| `Passes/EcoToLLVMRuntime.cpp:663-709` | emitSafepointMarker -> no-op | 4c |
| `Passes/EcoToLLVMRuntime.cpp:715-745` | emitWrapperSafepointMarker -> no-op | 4d |
| `Passes/EcoToLLVMClosures.cpp` (~28 sites) | Remove emitSafepointMarker/Wrapper calls | 4c/4d |
| `Passes/EcoToLLVMHeap.cpp:1420-1433` | Remove inline marker in slow path | 4e |
| `Passes/EcoToLLVMRuntime.cpp:579-592` | Delete getOrCreateSafepointMarker | 4f |
| `Passes/EcoToLLVMInternal.h:~315` | Delete declaration | 4f |
| `EcoRunner.cpp:~189-194` | Replace StatepointConversion with RS4GC | 5a |
| `ecoc.cpp:~189,~245-250` | Replace StatepointConversion with RS4GC | 5a |
| `eco-boot.cpp:~586-612` | Replace StatepointConversion with RS4GC | 5a |
| `CMakeLists.txt:221` | Remove StatepointConversion.cpp | 5b |
| `Passes/StatepointConversion.cpp` | DELETE | 5b |
| `Passes/StatepointConversion.h` | DELETE | 5c |
| `RuntimeSymbols.cpp` | Remove __eco_safepoint_poll registration | 6 |
