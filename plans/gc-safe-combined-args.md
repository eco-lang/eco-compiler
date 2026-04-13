# Plan: GC-Safe Closure Calls (`combined_args` + `eco_pap_extend`)

## Problem

Two related GC-safety bugs in the C++ closure runtime:

### Bug A: Unrooted `combined_args` in `eco_closure_call_saturated`

`eco_closure_call_saturated` builds a stack-allocated `combined_args` array of HPointers
(via `buildEvaluatorArgs`), then calls `closure->evaluator(combined_args)`. If GC runs
during that evaluator call — or during `buildEvaluatorArgs` itself (which calls
`eco_alloc_int` to box unboxed captures) — nothing roots the HPointers in `combined_args`.
The GC can reclaim/relocate nursery objects they point to, causing use-after-free crashes.

Stage 7 self-compile crash: a captured closure HPointer (`0x40048c1`) gets reclaimed
and overwritten with a string, later crashing in `eco_pap_extend`.

### Bug B: Stale `old_closure` pointer in `eco_pap_extend`

`eco_pap_extend` resolves `closure_hptr` to a raw `Closure* old_closure` once at the top,
then calls `Allocator::instance().allocate()` which can trigger GC. After GC, `old_closure`
may point into from-space (forwarded), but the code continues to read `old_closure->values[]`
to copy captures into the new PAP. This is a use-after-move bug.

The existing TRACE instrumentation already detects this: it checks `old_closure->header.tag
== Tag_Forward` after `allocate()`. The fix is to re-resolve from the authoritative HPointer.

### Both bugs are required for full safety

- If a PAP's captures are live only via `combined_args`: Bug A fix roots them so GC doesn't reclaim.
- If a PAP is live but moved during GC: Bug B fix re-resolves so we don't read from-space.

## Approach

### Bug A fix

Use the existing `eco_gc_push_stack_range` API — already used by MLIR-generated code in
`EcoToLLVMClosures.cpp` — to register `combined_args` as a GC root range **before**
`buildEvaluatorArgs` populates it, and restore it after the evaluator returns.

Registering **before** `buildEvaluatorArgs` is critical because `buildEvaluatorArgs`
itself calls `eco_alloc_int` (to box unboxed captures), which can trigger GC. Already-
written `out_args` entries must be rooted during those allocations.

### Bug B fix

After `Allocator::allocate()` in `eco_pap_extend`, re-resolve `old_closure` from
`closure_hptr` before reading any heap fields. Scalar values (`n_values`, `max_values`,
`old_unboxed`) read before allocation are safe to keep — they're in registers/locals.

## Scope

Both fixes are in the same "closure GC safety" series. A third related bug
(`buildEvaluatorArgs` closure re-resolve, PR C) is tracked separately.

- **PR C (separate):** `buildEvaluatorArgs` — the `Closure* closure` parameter goes stale
  after `eco_alloc_int` triggers GC mid-loop. Fix: pass `closure_hptr` and re-resolve
  after each boxing allocation.

## Key Design Decisions

1. **All-boxed mask**: Every slot in `combined_args` is an HPointer at the ABI boundary
   (unboxed captures are boxed by `buildEvaluatorArgs`). The mask is `(1ULL << max_values) - 1`.
   We do NOT use `closure->unboxed` — that describes heap layout, not `combined_args` layout.

2. **Zero-initialize before registering**: Following the pattern in `EcoToLLVMClosures.cpp`
   (`emitPushArgsRootRange`), we zero-fill `combined_args` before pushing it as a root range.
   This ensures the GC sees valid zero values (not garbage) for slots not yet populated.

3. **Register before `buildEvaluatorArgs`**: Because `buildEvaluatorArgs` can trigger GC
   via `eco_alloc_int`, the root range must be active during that call, not just during
   the evaluator call.

4. **Max arity is capped at 63**: `Closure.n_values` and `Closure.max_values` are 6-bit
   fields (0-63), so `max_values <= 63` is guaranteed by representation. This fits within
   the 64-bit `hpointer_mask`. No multi-range splitting needed. Assert `max_values <= 63`.

5. **`new_args` is already rooted by callers**: MLIR-generated call sites register their
   alloca-backed args arrays via `eco_gc_push_stack_range` before calling into the runtime.
   Pure C++ callers that bypass MLIR would need their own rooting, but that's out of scope.

6. **Re-resolve only heap pointers, not scalars**: In `eco_pap_extend`, scalar values
   (`n_values`, `max_values`, `old_unboxed`) read before `allocate()` are safe in
   registers/locals. Only the raw `Closure*` needs re-resolution after GC.

7. **No MLIR/LLVM changes needed**: Both fixes are purely C++ runtime.

## Files to Modify

All changes are in two files:
- `runtime/src/allocator/RuntimeExports.cpp`
- `runtime/src/allocator/RuntimeExports.h`

### 1. `RuntimeExports.cpp` — `eco_closure_call_saturated` (~line 1040)

**Current code** (lines 1040-1090):
```cpp
uint64_t eco_closure_call_saturated(uint64_t closure_hptr, uint64_t* new_args, uint32_t num_newargs) {
    // ... resolve closure, get max_values ...
    void* stack_args[16];
    void** combined_args = (max_values <= 16) ? stack_args :
                           static_cast<void**>(alloca(max_values * sizeof(void*)));
    // TRACE scaffolding ...
    buildEvaluatorArgs(closure, new_args, num_newargs, combined_args);
    // TRACE scaffolding ...
    void* result = closure->evaluator(combined_args);
    return reinterpret_cast<uint64_t>(result);
}
```

**After:**
```cpp
uint64_t eco_closure_call_saturated(uint64_t closure_hptr, uint64_t* new_args, uint32_t num_newargs) {
    // ... resolve closure, get max_values ...
    assert(max_values <= 63 && "max_values exceeds 6-bit field cap");

    void* stack_args[16];
    void** combined_args = (max_values <= 16) ? stack_args :
                           static_cast<void**>(alloca(max_values * sizeof(void*)));

    // Zero-init so GC sees valid values for not-yet-populated slots.
    memset(combined_args, 0, max_values * sizeof(void*));

    // Root combined_args as a stack root range during buildEvaluatorArgs + evaluator call.
    size_t saved_range = eco_gc_stack_range_point();
    if (max_values > 0) {
        uint64_t mask = (uint64_t{1} << max_values) - 1;
        eco_gc_push_stack_range(
            reinterpret_cast<uint64_t*>(combined_args),
            max_values,
            mask);
    }

    buildEvaluatorArgs(closure, new_args, num_newargs, combined_args);
    void* result = closure->evaluator(combined_args);

    eco_gc_restore_stack_range_point(saved_range);
    return reinterpret_cast<uint64_t>(result);
}
```

### 2. `RuntimeExports.cpp` — `eco_pap_extend` (~line 974)

**Current code** (lines 974-1038):
```cpp
uint64_t eco_pap_extend(uint64_t closure_hptr, uint64_t* args, uint32_t num_newargs,
                        uint64_t new_unboxed_bitmap) {
    Closure* old_closure = resolve_closure(closure_hptr);
    const uint32_t old_n_values = old_closure->n_values;
    const uint32_t max_values   = old_closure->max_values;
    const uint64_t old_unboxed  = old_closure->unboxed;
    // ... compute new_n_values, sanity check ...

    void* obj = Allocator::instance().allocate(size, Tag_Closure);  // may GC

    // TRACE: Tag_Forward check ...

    Closure* new_closure = static_cast<Closure*>(obj);
    new_closure->evaluator = old_closure->evaluator;   // BUG: old_closure may be stale

    for (uint32_t i = 0; i < old_n_values; i++) {
        new_closure->values[i] = old_closure->values[i];  // BUG: old_closure may be stale
    }
    // ... copy new args ...
    return ptrToHPointer(obj);
}
```

**After:**
```cpp
uint64_t eco_pap_extend(uint64_t closure_hptr, uint64_t* args, uint32_t num_newargs,
                        uint64_t new_unboxed_bitmap) {
    Closure* old_closure = resolve_closure(closure_hptr);

    // Read scalar header fields into locals before any GC-triggering call.
    // These are safe in registers across GC — only heap pointers go stale.
    const uint32_t old_n_values = old_closure->n_values;
    const uint32_t max_values   = old_closure->max_values;
    const uint64_t old_unboxed  = old_closure->unboxed;

    const uint32_t new_n_values = old_n_values + num_newargs;
    if (new_n_values > max_values) { /* existing error path */ }

    size_t size = sizeof(Header) + 8 + sizeof(EvalFunction) + new_n_values * sizeof(Unboxable);
    void* obj = Allocator::instance().allocate(size, Tag_Closure);  // may GC
    if (!obj) return 0;

    // Re-resolve old_closure: allocate() may have triggered GC and moved it.
    old_closure = static_cast<Closure*>(hpointerToPtr(closure_hptr));

    Closure* new_closure = static_cast<Closure*>(obj);
    new_closure->n_values   = new_n_values;
    new_closure->max_values = max_values;
    new_closure->evaluator  = old_closure->evaluator;  // now safe

    uint64_t masked_new_bitmap = new_unboxed_bitmap & ((1ULL << num_newargs) - 1);
    uint64_t shifted_new_bitmap = masked_new_bitmap << old_n_values;
    new_closure->unboxed = old_unboxed | shifted_new_bitmap;

    // Copy old captured values from re-resolved old_closure.
    for (uint32_t i = 0; i < old_n_values; i++) {
        new_closure->values[i] = old_closure->values[i];  // now safe
    }

    // Copy new arguments.
    for (uint32_t i = 0; i < num_newargs; i++) {
        new_closure->values[old_n_values + i].i = static_cast<i64>(args[i]);
    }

    return ptrToHPointer(obj);
}
```

### 3. `RuntimeExports.cpp` — `buildEvaluatorArgs` (~line 834)

Remove TRACE `fprintf` blocks:
- The `TRACE_BEA` Tag_Forward check after `eco_alloc_int` (lines ~853-862)

### 4. `RuntimeExports.cpp` — TRACE removal in `eco_closure_call_saturated` and `eco_pap_extend`

Remove all crash-investigation TRACE `fprintf` blocks:
- `TRACE_CAPTURE` block checking for `0x40048c1` in `eco_closure_call_saturated` (lines ~1058-1071)
- `TRACE_SAT` Tag_Forward check after `buildEvaluatorArgs` in `eco_closure_call_saturated` (lines ~1077-1086)
- `TRACE_PAP` Tag_Forward check after `allocate()` in `eco_pap_extend` (lines ~1002-1012)

These are crash-investigation scaffolding with hard-coded addresses. If similar diagnostics
are needed in future, introduce generic opt-in tracing (e.g. `ECO_TRACE_GC_ROOTS` behind
a compile-time flag).

### 5. `RuntimeExports.h` — Comment update (~line 333)

Update the doc comment from:
```cpp
/// Stack root range management for compiled code.
/// Registers contiguous stack arrays as GC root ranges so the collector
/// can trace HPointers stored in alloca-backed args arrays.
```
to:
```cpp
/// Stack root range management for compiled code and C++ runtime.
/// Registers contiguous stack arrays as GC root ranges so the collector
/// can trace HPointers stored in alloca- or stack-backed args arrays
/// (e.g., LLVM alloca args, C++ combined_args for closure evaluators).
```

## Files NOT Modified

- No MLIR codegen changes
- No `RootSet.hpp` changes
- No `GCInterface.cpp` changes
- The `eco_gc_stack_range_point` / `eco_gc_push_stack_range` / `eco_gc_restore_stack_range_point`
  implementations already exist and are correct (RuntimeExports.cpp lines 2283-2296)

## Step-by-Step Implementation

### Step 1: Remove all TRACE debug instrumentation
- Remove the `TRACE_BEA` Tag_Forward check in `buildEvaluatorArgs` (lines ~853-862)
- Remove the `TRACE_CAPTURE` fprintf block in `eco_closure_call_saturated` (lines ~1058-1071)
- Remove the `TRACE_SAT` Tag_Forward check in `eco_closure_call_saturated` (lines ~1077-1086)
- Remove the `TRACE_PAP` Tag_Forward check in `eco_pap_extend` (lines ~1002-1012)

### Step 2: Fix `eco_closure_call_saturated` (Bug A — root `combined_args`)
- Add `assert(max_values <= 63)` after reading max_values
- After allocating `combined_args`, add `memset` zero-initialization
- Add `eco_gc_stack_range_point()` save
- Add mask computation and `eco_gc_push_stack_range()` call (guarded by `max_values > 0`)
- `buildEvaluatorArgs` + `closure->evaluator` call remain between push/restore
- Add `eco_gc_restore_stack_range_point()` after evaluator returns, before return

### Step 3: Fix `eco_pap_extend` (Bug B — re-resolve after allocate)
- After `Allocator::instance().allocate()`, add re-resolve:
  `old_closure = static_cast<Closure*>(hpointerToPtr(closure_hptr));`
- All subsequent reads from `old_closure` (evaluator, values[]) now use the re-resolved pointer
- Scalar locals (`old_n_values`, `max_values`, `old_unboxed`) remain unchanged — safe in registers

### Step 4: Update RuntimeExports.h comment
- Broaden the doc comment for the stack range API to mention C++ runtime use

### Step 5: Build and test
- `cmake --build build --target full`
- Verify Stage 7 self-compile no longer crashes

## Testing Plan

1. **E2E tests**: `cmake --build build --target full` — all existing tests pass
2. **Stage 7 self-compile**: The crash scenario (`Bytes_Decode_loopHelp` with stale closure)
   should no longer reproduce
3. **Performance**: The extra calls (`eco_gc_stack_range_point` / `eco_gc_push_stack_range`
   + one `hpointerToPtr` re-resolve) are trivial operations — no measurable overhead expected

## Resolved Questions

1. **`eco_pap_extend` bug** — Now included in this plan (Bug B). Same PR.
2. **TRACE instrumentation** — Remove in this PR. Hard-coded addresses don't belong in mainline.
3. **Max arity cap** — 6-bit fields cap at 63. Fits in 64-bit mask. Assert and use simple shift.
4. **`buildEvaluatorArgs` closure re-resolve** — Separate PR (PR C). The raw `Closure*` inside
   `buildEvaluatorArgs` can go stale during `eco_alloc_int`. Fix by passing `closure_hptr` and
   re-resolving after each boxing allocation.
5. **`new_args` rooting** — Already handled by MLIR-generated callers via `eco_gc_push_stack_range`.
   Pure C++ callers are out of scope for this fix.
