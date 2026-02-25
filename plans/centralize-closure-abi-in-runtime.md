# Centralize Closure ABI & Boxing/Unboxing in the Runtime

## Goal

Make the **runtime** (`RuntimeExports.cpp`) the single owner of "closure ABI & boxing/unboxing" and remove that knowledge from kernels and EcoToLLVM's legacy path.

---

## Current State (from codebase exploration)

### Three independent implementations of closure bitmap/boxing/evaluator-call logic:

1. **Runtime** (`runtime/src/allocator/RuntimeExports.cpp`):
   - `eco_closure_call_saturated` (lines 590-636): reads `closure->unboxed`, boxes unboxed captures via `eco_alloc_int`, builds combined args, calls `evaluator(args)`
   - `eco_apply_closure` (lines 491-534): identical inline bitmap/boxing logic in its saturated branch
   - Both functions duplicate the same pattern independently

2. **Kernels** (3 files with violations):
   - `elm-kernel-cpp/src/core/ListExports.cpp` (lines 28-110): `loadCapturedValues()` + 5 `callXxxClosure()` helpers, all directly calling `closure->evaluator(args)`
   - `elm-kernel-cpp/src/core/JsArrayExports.cpp` (lines 44-106): `loadCapturedValues()` + 4 `callXxxClosure()` helpers, all directly calling `closure->evaluator(args)`
   - `elm-kernel-cpp/src/core/StringExports.cpp` (lines 143-203): `loadCapturedValues()` + 3 `callXxxClosure()` helpers, all directly calling `closure->evaluator(args)`

3. **EcoToLLVM** (`runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`):
   - `emitInlineClosureCall()` (lines 665-898): the "legacy" fallback path that builds args arrays in LLVM IR, reads `packed >> 12` for unboxed bitmap, boxes captures via `scf.if` + `eco_alloc_int/float/char`, and calls `evaluator(args)`

### Already compliant (no changes needed):
- **BytesExports.cpp**: Already uses `eco_closure_call_saturated` (line 362)
- **JsonExports.cpp**: Uses `eco_apply_closure` (lines 767, 809, 835, 864, 1337)
- **RegexExports.cpp**: Uses `eco_apply_closure` (line 354)
- **HttpExports.cpp**: Uses `eco_apply_closure` (lines 238, 325, 352, 441, 453)
- **TimeEffectManager.cpp**: Uses `eco_apply_closure` (lines 86, 243, 246)
- **Scheduler.cpp**: `callClosure1/2/4` all use `eco_apply_closure` (lines 89, 99, 112)
- **ProcessExports.cpp**: Uses `Scheduler::callClosure*`

### EcoToLLVM has THREE distinct call paths (not two):

1. **Fast path** (`emitFastClosureCall`, lines 483-546): Direct typed call to fast clone. `_dispatch_mode="fast"`. No evaluator, no bitmap. **Leave as-is.**
2. **Generic closure path** (`emitClosureCall`, lines 551-592): Indirect call via evaluator with `closure_ptr` as first arg. `_dispatch_mode="closure"`. Generic clone unpacks captures. **Leave as-is.**
3. **Legacy inline path** (`emitInlineClosureCall`, lines 665-898): Builds `void*[]` args array, reads packed bitmap, boxes captures, calls wrapper. Fallback when no `_dispatch_mode` or `_dispatch_mode="unknown"`. **This is the target for change.**

---

## Target Invariants After Refactor

- **INV_1 (Single evaluator callsite)**: There is exactly **one** C++ function that reads `Closure::unboxed` bitmap, boxes unboxed captured `Unboxable` values, and calls `EvalFunction evaluator(void*[])`. It lives in `RuntimeExports.cpp`.

- **INV_2 (Runtime owns closure call ABI)**: All closure calls from C++ kernels and EcoToLLVM's legacy path go through `eco_closure_call_saturated` / `eco_apply_closure`, never directly through `cl->evaluator`.

- **INV_3 (Compiler only owns bitmap construction)**: The compiler/MLIR computes `unboxed_bitmap` from SSA types (per `CGEN_003`), but does not interpret bit layout at call time. Closures are opaque heap objects with "number of new args".

- **INV_4 (Kernels see opaque closures)**: Kernels treat closure arguments as opaque `uint64_t` Elm values (HPointers). They box new primitive arguments via `eco_alloc_int/float/char` and call runtime helpers. They never read `Closure::unboxed`, `Closure::values[]`, or `cl->evaluator`.

- **INV_5 (Bit-pattern boxing for closure captures)**: When boxing an unboxed closure capture for the evaluator, the runtime always uses `eco_alloc_int()` regardless of the capture's logical type (Int, Float, or Char). The heap tag on the resulting object is **not trusted** by the evaluator — it treats the value as a raw 64-bit container. The evaluator (wrapper function) knows the original type from its compiled signature and reinterprets the raw bits accordingly (identity for Int, bitcast for Float, truncate for Char). This is intentional and correct because ElmInt, ElmFloat, and ElmChar all store their value at the same offset after the Header.

- **INV_6 (No over-saturation)**: `eco_apply_closure` assumes `n_values + num_args <= max_values`. Over-saturation (more args than remaining arity) is prevented by staging invariants in the compiler (`GOPT_001`, `GOPT_011-014`). A debug assert enforces this at runtime; violation indicates a compiler bug.

---

## Step 1: Consolidate Runtime Internals

**Files**: `runtime/src/allocator/RuntimeExports.cpp`

### 1.1 Extract `buildEvaluatorArgs` internal helper

Add a static helper in `RuntimeExports.cpp` that encapsulates the bitmap interpretation + boxing + arg array construction:

```cpp
namespace {

size_t buildEvaluatorArgs(
    Closure* closure,
    const uint64_t* new_args, uint32_t num_newargs,
    void** out_args  // note: void** not uint64_t*
) {
    const uint32_t nCaptured = closure->n_values;
    const uint64_t bitmap    = closure->unboxed;
    size_t idx = 0;

    // 1. Captured values: box unboxed ones
    for (uint32_t i = 0; i < nCaptured; ++i) {
        uint64_t val = closure->values[i].i;
        if ((bitmap >> i) & 1) {
            val = eco_alloc_int(static_cast<int64_t>(val));
        }
        out_args[idx++] = reinterpret_cast<void*>(val);
    }

    // 2. New args (already HPointer-encoded)
    for (uint32_t j = 0; j < num_newargs; ++j) {
        out_args[idx++] = reinterpret_cast<void*>(new_args[j]);
    }

    return idx;
}

} // namespace
```

**Boxing approach (INV_5)**: `buildEvaluatorArgs` always uses `eco_alloc_int()` for all unboxed captures regardless of logical type. This is intentional bit-pattern boxing — the bitmap has only a 1-bit-per-slot presence flag with no type information. The evaluator (wrapper function) knows the original types from its compiled signature and reinterprets the raw i64 bits accordingly:
- Int: identity (read i64 as-is)
- Float: bitcast i64 to f64 (preserves IEEE 754 representation)
- Char: truncate i64 to i16 (lower 16 bits)

This works because ElmInt, ElmFloat, and ElmChar all store their value at the same 8-byte-aligned offset after the Header. The heap tag on the boxing object is **not trusted** by the evaluator. Add a comment in `buildEvaluatorArgs` documenting this invariant.

### 1.2 Rewrite `eco_closure_call_saturated` to use `buildEvaluatorArgs`

Replace the inline bitmap/boxing loop (lines 614-627) with a call to `buildEvaluatorArgs`. The overall structure stays the same:

```cpp
extern "C" uint64_t eco_closure_call_saturated(uint64_t closure_hptr, uint64_t* new_args, uint32_t num_newargs) {
    void* closure_ptr = hpointerToPtr(closure_hptr);
    if (!closure_ptr) return 0;
    Closure* closure = static_cast<Closure*>(closure_ptr);

    uint32_t max_values = closure->max_values;
    // assert: closure->n_values + num_newargs == max_values

    void* stack_args[16];
    void** combined_args = (max_values <= 16) ? stack_args :
                           static_cast<void**>(alloca(max_values * sizeof(void*)));

    buildEvaluatorArgs(closure, new_args, num_newargs, combined_args);

    void* result = closure->evaluator(combined_args);
    return reinterpret_cast<uint64_t>(result);
}
```

### 1.3 Rewrite `eco_apply_closure` saturated branch to delegate

Replace the saturated branch (lines 504-522) to simply call `eco_closure_call_saturated`, and replace the over-saturated branch with a debug assert (INV_6):

```cpp
if (total == max_values) {
    // Saturated: delegate to single evaluator callsite (INV_1)
    return eco_closure_call_saturated(closure_hptr, args, num_args);
} else if (total < max_values) {
    // Partial: extend PAP
    return eco_pap_extend(closure_hptr, args, num_args, 0);
} else {
    // Over-saturated: staging invariants (GOPT_001, GOPT_011-014) prevent this.
    // If we reach here, it indicates a compiler bug.
    assert(false && "eco_apply_closure: over-saturated call — compiler staging invariant violated");
    __builtin_unreachable();
}
```

**Testing checkpoint**: Run `cmake --build build --target check` after Step 1. All tests should pass since behavior is unchanged.

---

## Step 2: Update Kernel Files

### 2.1 ListExports.cpp

**Delete** (lines 28-110):
- `loadCapturedValues()` (lines 28-39)
- `callUnaryClosure()` (lines 42-50)
- `callBinaryClosure()` (lines 53-63)
- `callTernaryClosure()` (lines 66-77)
- `callQuaternaryClosure()` (lines 80-93)
- `callQuinaryClosure()` (lines 96-110)

**Replace with** thin wrappers that call `eco_closure_call_saturated`:

```cpp
// Takes a closure HPointer + N new HPointer args, calls through runtime
inline uint64_t callUnaryClosure(uint64_t closure_hptr, uint64_t arg) {
    uint64_t args[1] = { arg };
    return eco_closure_call_saturated(closure_hptr, args, 1);
}

inline uint64_t callBinaryClosure(uint64_t closure_hptr, uint64_t arg1, uint64_t arg2) {
    uint64_t args[2] = { arg1, arg2 };
    return eco_closure_call_saturated(closure_hptr, args, 2);
}
// ... similarly for ternary, quaternary, quinary
```

**Callers must be updated**: The existing callers pass `void* closure_ptr` (resolved raw pointer). After the refactor, they must pass `uint64_t closure_hptr` (the HPointer) instead, since `eco_closure_call_saturated` takes an HPointer and resolves it internally.

This means every call site that currently does:
```cpp
void* closure_ptr = allocator.resolve(closureHP);
callUnaryClosure(closure_ptr, arg);
```
becomes:
```cpp
uint64_t closure_hptr = encodeHP(closureHP);  // or the raw uint64_t already
callUnaryClosure(closure_hptr, arg);
```

The `Closure*` casts are removed entirely. Kernels no longer need `#include "Heap.hpp"` for `Closure` struct access (only for other types they use like `Cons`, `String`, etc.).

### 2.2 JsArrayExports.cpp

Same pattern. **Delete** (lines 44-106):
- `loadCapturedValues()` (lines 44-54)
- `callUnaryInitClosure()` (lines 58-66)
- `callUnaryMapClosure()` (lines 70-78)
- `callBinaryIndexMapClosure()` (lines 82-92)
- `callBinaryFoldClosure()` (lines 96-106)

**Replace** with wrappers calling `eco_closure_call_saturated`. Update callers to pass HPointer instead of resolved raw pointer.

### 2.3 StringExports.cpp

Same pattern. **Delete** (lines 143-203):
- `loadCapturedValues()` (lines 143-153)
- `callCharToCharClosure()` (lines 158-174)
- `callCharToBoolClosure()` (lines 178-188)
- `callFoldClosure()` (lines 192-203)

**Replace** with wrappers. Note: `callCharToCharClosure` and `callCharToBoolClosure` have special behavior:
- They box the char argument via `eco_alloc_char()` **before** calling the closure
- They unbox the result (resolve HPointer, read `ElmChar->value` or interpret as Bool)

The replacement keeps the boxing/unboxing of *new arguments and results* in the kernel, but delegates the *captured-value handling and evaluator calling* to the runtime:

```cpp
static uint16_t callCharToCharClosure(uint64_t closure_hptr, uint16_t c) {
    uint64_t boxed_char = eco_alloc_char(static_cast<uint32_t>(c));
    uint64_t result_hptr = eco_closure_call_saturated(closure_hptr, &boxed_char, 1);
    // Unbox result: resolve HPointer, read ElmChar->value
    void* charObj = reinterpret_cast<void*>(eco_resolve_hptr(result_hptr));
    ElmChar* ec = static_cast<ElmChar*>(charObj);
    return ec->value;
}
```

### 2.4 BytesExports.cpp

**No changes needed** - already uses `eco_closure_call_saturated` (line 362) and `eco_apply_closure` (line 86).

**Testing checkpoint**: Run `cmake --build build --target check` after Step 2. This is the critical test point since the calling convention changes from resolved-pointer to HPointer.

---

## Step 3: EcoToLLVM Legacy Path

**Files**: `runtime/src/codegen/Passes/EcoToLLVMClosures.cpp`

### 3.1 Only change `emitInlineClosureCall` (lines 665-898)

This is the fallback path triggered when:
- No `_dispatch_mode` attribute exists, OR
- `_dispatch_mode="unknown"`

Currently it:
1. Loads `packed` field from closure, extracts `n_values`, `max_values`, `unboxed` bitmap
2. Allocates `argsArray = alloca [totalArgs x i64]`
3. Loops over captured values with `scf.while`, checking bitmap to conditionally box via `eco_alloc_int/float/char`
4. Copies new arguments (boxing based on original MLIR types)
5. Calls `evaluator(argsArray)` indirectly
6. Unboxes result based on original result type

**Replace steps 1-5** with:
1. Keep closure value as i64 HPointer
2. Box new arguments to HPointer (this part stays, as new args need boxing based on their MLIR types)
3. Store new args in `[N x i64]` array
4. Emit call to `eco_closure_call_saturated(closure_hptr, new_args_ptr, N)`
5. Handle result type conversion (HPointer -> primitive) using existing conventions

### 3.2 Do NOT change `emitFastClosureCall` or `emitClosureCall`

- **Fast path** (`_dispatch_mode="fast"`): Direct typed call, no bitmap involved. Untouched.
- **Generic closure path** (`_dispatch_mode="closure"`): Uses a different convention (closure_ptr as first arg to generic clone, which unpacks captures itself). Untouched.

### 3.3 For saturated `papExtend` that falls through to legacy

In the `papExtend` lowering, the saturated case checks for fast/generic dispatch first. If neither is available, it falls through to `emitInlineClosureCall`. After this refactor, that fallback automatically goes through the new runtime-delegating path.

### 3.4 Wrapper function generation (`getOrCreateWrapper`)

After this refactor, the wrapper functions generated by `getOrCreateWrapper` (which bridge `void*[]` → typed ABI) are still needed. They are called by `eco_closure_call_saturated` via the `evaluator` function pointer. The wrappers continue to handle the typed unboxing of args (including the bit-pattern reinterpretation per INV_5). No changes needed to wrapper generation.

**Testing checkpoint**: Run full test suite after Step 3. Test especially:
- Cases that produce `_dispatch_mode="unknown"` closures (heterogeneous merge points)
- Elm packages that exercise complex closure patterns

---

## Resolved Design Decisions

### D1: Bit-pattern boxing for closure captures (INV_5)

**Decision**: Keep `eco_alloc_int()` as the sole boxing function for all unboxed captures. Document this as an intentional bit-pattern boxing trick with a clear invariant (INV_5) stating that heap tags are not trusted for closure-boxed primitives.

**Rationale**: The bitmap has only a 1-bit-per-slot presence flag — no type information. The evaluator (wrapper) knows original types from its compiled signature and reinterprets raw bits accordingly. Adding type tags to the bitmap would require compiler changes for no functional benefit.

### D2: GC safety with HPointer calling convention

**Decision**: No special handling needed. The `args[]` arrays passed to `eco_closure_call_saturated` are stack-local temporaries, not GC roots. All referenced objects remain reachable via normal roots (the closure itself and the caller's stack frame). HPointers are stable across GC (they're offsets, not raw pointers), so the refactor is actually slightly safer than the current resolved-pointer approach.

### D3: EcoToLLVM legacy path performance

**Decision**: Route the legacy inline path through `eco_closure_call_saturated`. The overhead of a function call on a rare, already-slow fallback path is acceptable. The fast typed path (`emitFastClosureCall`) and generic clone path (`emitClosureCall`) remain fully optimized with zero overhead from this refactor.

### D4: Over-saturation in `eco_apply_closure` (INV_6)

**Decision**: Do not implement general over-saturation handling. The compiler's staging invariants (`GOPT_001`, `GOPT_011-014`) guarantee that calls are never over-saturated. Replace the current `fprintf + return 0` with a debug assert and `__builtin_unreachable()` to make the assumption explicit and catch compiler bugs early.

---

## Migration Strategy

1. **Step 1** (runtime-only): Extract `buildEvaluatorArgs`, rewrite `eco_closure_call_saturated` and `eco_apply_closure`. Run tests.
2. **Step 2** (kernels): Update ListExports, JsArrayExports, StringExports. Run tests. This is the highest-risk step due to calling convention changes.
3. **Step 3** (EcoToLLVM): Update legacy inline path. Run tests. Lowest risk since this is a fallback path.

After all three steps, the **only** place that reads `Closure::unboxed` and calls `evaluator(void*[])` is `buildEvaluatorArgs` in `RuntimeExports.cpp`.

---

## Invariant Documentation

After implementation, add the following to `design_docs/invariants.csv`:

| ID | Category | Description |
|----|----------|-------------|
| `RUNTIME_CLOSURE_001` | Runtime | `buildEvaluatorArgs` in `RuntimeExports.cpp` is the single implementation that reads `Closure::unboxed`, boxes captured `Unboxable` values, and constructs the `void*[]` evaluator argument array. No other code may interpret closure capture bitmaps or call `EvalFunction` directly. |
| `RUNTIME_CLOSURE_002` | Runtime | Unboxed closure captures are boxed via `eco_alloc_int()` as a bit-pattern container. The heap tag (Tag_Int) is NOT trusted by the evaluator wrapper. The wrapper reinterprets raw i64 bits according to the original compiled type (identity for Int, bitcast for Float, truncate for Char). |
| `RUNTIME_CLOSURE_003` | Runtime | `eco_apply_closure` requires `n_values + num_args <= max_values`. Over-saturation is prevented by compiler staging invariants (GOPT_001, GOPT_011-014). Violation triggers a debug assert. |

---

## Test Coverage

### Existing tests that should catch regressions:
- Full E2E suite (`cmake --build build --target check`)
- Elm-test frontend tests (`cd compiler && npx elm-test-rs --fuzz 1`)
- Filter-specific tests: `TEST_FILTER=elm cmake --build build --target check`

### Specific scenarios to verify:
- Closure with mixed unboxed/boxed captures called from kernel (List.foldl, String.map, JsArray.foldl)
- Closure with zero captures called from kernel
- Closure with all-unboxed captures
- Bytes decoder (already uses `eco_closure_call_saturated` — regression canary)
- Heterogeneous closures at case merge points (legacy EcoToLLVM path)
- String.map / String.filter (Char boxing/unboxing round-trip via INV_5)
- Float-capturing closures called through kernels (tests bit-pattern boxing for Float)

### Debug assert verification:
- Confirm the over-saturation assert (INV_6) fires in debug builds if staging invariants are violated (can be tested with a synthetic test that deliberately over-saturates)
