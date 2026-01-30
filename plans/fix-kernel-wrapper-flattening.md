# Plan: Fix Kernel Wrapper Flattening

## Problem Summary

Kernel wrapper functions like `Bitwise_or_$_1` are generated with a type/body mismatch:

- **Type:** Flattened (e.g., `Int -> Int` after uncurrying)
- **Body:** Stage-curried (creates PAP, applies one arg, returns closure)

This causes incorrect MLIR where a closure is unboxed as an integer:

```mlir
func.func @Bitwise_or_$_1(%arg0: i64) -> i64 {
  %1 = "eco.papCreate"() {arity = 2, function = @Elm_Kernel_Bitwise_or}
  %2 = "eco.papExtend"(%1, %arg0) {remaining_arity = 1}  // Returns closure!
  %3 = "eco.unbox"(%2)  // Tries to unbox closure as i64 - WRONG
  "eco.return"(%3)
}
```

## Root Cause

In `Compiler.Generate.Monomorphize.Closure.ensureCallableTopLevel`, the `MonoVarKernel` branch uses stage arity:

```elm
Mono.MonoVarKernel region home name kernelAbiType ->
    let
        kernelStageArgTypes =
            Types.stageParamTypes kernelAbiType      -- ❌ Stage-curried

        kernelStageRetType =
            Types.stageReturnType kernelAbiType      -- ❌ Stage-curried
    in
    makeAliasClosure
        (Mono.MonoVarKernel region home name kernelAbiType)
        region
        kernelStageArgTypes
        kernelStageRetType
        kernelAbiType
        state
```

This creates a closure that only takes the first stage's arguments and returns a closure for the rest, but the type system expects it to be fully flattened.

## Solution

Use flattened arity for kernel wrappers. The `flattenFunctionType` helper already exists in the same file (line 109).

---

## Implementation Steps

### Step 1: Fix the `MonoVarKernel` Branch in `ensureCallableTopLevel`

**File:** `compiler/src/Compiler/Generate/Monomorphize/Closure.elm`

**Location:** Lines 81-97

**Change:**

```elm
-- Before (lines 81-97):
Mono.MonoVarKernel region home name kernelAbiType ->
    -- MONO_016: Create stage-aware closure wrapper
    -- Use kernel ABI type for params (ABI stability)
    let
        kernelStageArgTypes =
            Types.stageParamTypes kernelAbiType

        kernelStageRetType =
            Types.stageReturnType kernelAbiType
    in
    makeAliasClosure
        (Mono.MonoVarKernel region home name kernelAbiType)
        region
        kernelStageArgTypes
        kernelStageRetType
        kernelAbiType
        state

-- After:
Mono.MonoVarKernel region home name kernelAbiType ->
    -- Kernels use flattened ABI (all params at once), not stage-curried.
    -- Create a fully flattened alias closure that calls the kernel with all args.
    let
        ( kernelFlatArgTypes, kernelFlatRetType ) =
            flattenFunctionType kernelAbiType
    in
    makeAliasClosure
        (Mono.MonoVarKernel region home name kernelAbiType)
        region
        kernelFlatArgTypes
        kernelFlatRetType
        kernelAbiType
        state
```

### Step 2: Verify Wrapper Generation

After Step 1, the wrapper `Bitwise_or_$_1` should conceptually be:

- A `MonoClosure` whose `closureInfo.params` list matches the **flattened ABI parameters** of `kernelAbiType`, i.e. two `Int` parameters for `Bitwise.or`.
- A body that is a **saturated** `MonoCall` to `MonoVarKernel "Bitwise" "or"` with *all* those parameters as arguments.
- A `funcType` on the closure that still reflects the original source-level function type (which may be curried), but whose *implementation* is flattened at the ABI level.

Concretely, you should verify in MLIR that the generated wrapper function:

- Has one block argument per flattened ABI parameter (for `Bitwise.or`, two `i64` args).
- Performs a **direct saturated call** to `@Elm_Kernel_Bitwise_or` with both arguments.
- Does **not** contain any `eco.papCreate`/`eco.papExtend` in the wrapper body.
- Does **not** `eco.unbox` a closure result.

Example shape (names/types may vary, focus on structure):

```mlir
func.func @Bitwise_or_$_1(%arg0: i64, %arg1: i64) -> i64 {
  %0 = call @Elm_Kernel_Bitwise_or(%arg0, %arg1) : (i64, i64) -> i64
  return %0 : i64
}
```

### Step 3: Update Tests

**File:** `compiler/tests/Compiler/Generate/MonomorphizeTest.elm`

Add or update tests for kernel wrapper generation:

1. Test that `ensureCallableTopLevel` with a kernel creates a fully-parameterized closure
2. Test that the wrapper's params match the kernel's full ABI arity
3. Test that the wrapper's body is a saturated call, not a partial application

### Step 4: Run Full Test Suite

```bash
cd compiler && npx elm-test-rs --fuzz 1
cmake --build build --target full
```

---

## Design Rationale

### Why Flatten Kernels But Not User Functions?

Per Option 4 (CGEN052_OPTION4_EXTERNAL_VS_CLOSURE.md):

| Category | Call Model | Arity Calculation |
|----------|------------|-------------------|
| Kernels (`MonoVarKernel`) | `FlattenedExternal` | Total ABI arity |
| Externs (`MonoExtern`) | `FlattenedExternal` | Total ABI arity |
| User closures (`MonoClosure`) | `StageCurried` | Stage arity per MONO_016 |
| Constructors (`MonoCtor`) | `FlattenedExternal` | Total ABI arity |

Kernels are C++ functions with a fixed flattened ABI. User closures are Elm functions that may be partially applied stage-by-stage. The wrapper around a kernel is a `MonoClosure` (user closure), but its *body* calls a flattened kernel with all arguments.

Note: the wrapper closure that `ensureCallableTopLevel` builds for a kernel is still a regular `MonoClosure` and will be treated as `StageCurried` by higher-order callers. The *closure body* is where we respect the flattened ABI: it calls the kernel with all ABI arguments at once. This separation is what allows higher-order code (`List.map`, etc.) to remain uniform while kernels keep a stable C++ ABI.

### Why Not Eliminate Wrappers Entirely?

Wrappers are needed when kernels escape into higher-order positions:

```elm
List.map Bitwise.or [1, 2, 3]  -- Bitwise.or used as a value
```

Here `Bitwise.or` must be a first-class closure value that can be stored, passed, and called via the uniform closure ABI. The wrapper provides this interface while internally calling the flattened kernel.

### What About Higher-Order Functions?

Inside `List.map`, the function parameter is always called via `StageCurried` semantics. The caller's responsibility (via `ensureCallableTopLevel`) is to wrap any kernel in a proper closure before passing it. `List.map` never sees a naked kernel - only closures.

---

## Verification Checklist

After implementation:

- [ ] `BitwiseOrTest.elm` generates correct MLIR: the wrapper body calls `@Elm_Kernel_Bitwise_or` in a saturated way and does not `eco.unbox` a closure. It is acceptable for a `papCreate` to exist when building first-class closures; it must not be used inside the kernel wrapper itself.
- [ ] `BitwiseIdentityTest.elm` passes
- [ ] All kernel-using tests pass (`TEST_FILTER=elm cmake --build build --target check`)
- [ ] Higher-order kernel usage works: `List.map Bitwise.or [1,2,3]`
- [ ] Partial application at call sites still works: `let f = Bitwise.or 5 in f 10`
- [ ] No regressions in codegen tests: `TEST_FILTER=codegen cmake --build build --target check`

---

## Files Changed

| File | Change |
|------|--------|
| `compiler/src/Compiler/Generate/Monomorphize/Closure.elm` | Fix `MonoVarKernel` branch to use flattened arity |
| `compiler/tests/Compiler/Generate/MonomorphizeTest.elm` | Add/update kernel wrapper tests |

---

## Questions Resolved

1. **Where do wrappers come from?** → `ensureCallableTopLevel` in `Closure.elm`
2. **Type vs body mismatch fix?** → Use flattened arity for kernel wrappers (option b)
3. **Function params with FlattenedExternal?** → Never. Params are always `StageCurried`/`Nothing`
4. **Higher-order kernel usage?** → Wrapper closures provide uniform interface; `List.map` sees closures only

## Assumptions

1. `flattenFunctionType` correctly decomposes the **kernel ABI type** into a flat `(argTypes, retType)` pair, so that `argTypes` matches the actual C++ kernel parameters in order and count.
2. `makeAliasClosure` works correctly with flattened arg lists
3. The MLIR codegen (`generateCall`) correctly handles saturated calls to kernels
4. No other places in the codebase depend on kernel wrappers being stage-curried
