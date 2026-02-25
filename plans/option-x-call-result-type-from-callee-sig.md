# Plan: Option X – Derive Call Result Type from Callee Signature

## Problem

In `generateSaturatedCall`'s `MonoVarGlobal` path, compiled (non-kernel) function calls compute their MLIR result type from the **caller's** `resultType` rather than the **callee's** `FuncSignature.returnType`. This violates **REP_ABI_001** when the callee is a polymorphic wrapper (e.g. JsArray wrappers) whose `func.func` returns `!eco.value`, but the monomorphized call site has `resultType = MInt` → `i64`.

### Concrete example

A JsArray wrapper like `Elm_JsArray_unsafeGet_$_37` is declared with `function_type = (i64, !eco.value) -> (!eco.value)` because its monotype has `MVar CEcoValue` → `!eco.value`. But the call site has `resultType = MInt`, so `Types.monoTypeToAbi resultType` produces `i64`. The emitted `eco.call` has result type `i64` against a callee returning `!eco.value` → MLIR verifier error.

### Existing precedent

Zero-arity function globals in `generateVarGlobal` (line 548-549) already use `sig.returnType`:
```elm
resultMlirType =
    Types.monoTypeToAbi sig.returnType
```
This is the correct pattern. The two compiled-function fallback paths in `generateSaturatedCall` should follow the same rule.

## Changes

**Single file:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

### Change 1: Core-module fallback → compiled function call (line 2120-2121)

**Location:** `generateSaturatedCall` → `MonoVarGlobal` → `maybeCoreInfo = Just (moduleName, name)` → `kernelIntrinsic` returns `Nothing` → `hasKernelImplementation` is `False` → comment "Fall back to compiled function call (e.g., min, max, abs, compare)"

**Current code (line 2120-2121):**
```elm
                                                    resultMlirType =
                                                        Types.monoTypeToAbi resultType
```

**New code:**
```elm
                                                    resultMlirType =
                                                        case maybeSig of
                                                            Just sig ->
                                                                Types.monoTypeToAbi sig.returnType

                                                            Nothing ->
                                                                Types.monoTypeToAbi resultType
```

### Change 2: Regular (non-core) function call (line 2158-2159)

**Location:** `generateSaturatedCall` → `MonoVarGlobal` → `maybeCoreInfo = Nothing` → comment "Regular function call (not a core module)"

**Current code (line 2158-2159):**
```elm
                                        resultMlirType =
                                            Types.monoTypeToAbi resultType
```

**New code:**
```elm
                                        resultMlirType =
                                            case maybeSig of
                                                Just sig ->
                                                    Types.monoTypeToAbi sig.returnType

                                                Nothing ->
                                                    Types.monoTypeToAbi resultType
```

## Why this is correct

1. **When `maybeSig` is `Just sig`:** `sig.returnType` is the same `MonoType` that was used when generating the callee's `func.func` declaration, so `Types.monoTypeToAbi sig.returnType` produces the same MLIR type as the callee's declared return type. The `eco.call` result type matches the `func.func` declaration → satisfies REP_ABI_001.

2. **When `maybeSig` is `Nothing`:** Falls back to previous behavior (`Types.monoTypeToAbi resultType`). This is a safety net for edge cases where no signature was registered.

3. **Boxing/unboxing is already handled:** If the call returns `!eco.value` but the consumer expects a primitive (e.g. `i64` for `Int`), existing mechanisms handle the conversion:
   - `coerceResultToType` for control flow / record fields
   - `Intrinsics.unboxArgsForIntrinsic` / `unboxToType` for arithmetic/comparisons
   - `boxToMatchSignatureTyped` for arguments to subsequent calls

4. **No other files need changes:** Wrapper declarations already use `Types.monoTypeToAbi` on their (possibly polymorphic) `MonoType`. Kernel calls use `kernelBackendAbiPolicy`. Intrinsic paths have their own result type logic.

## Questions

1. **Are there any compiled global calls where `sig.returnType` differs from `resultType` in ways _other_ than the wrapper case?** For monomorphic functions, `sig.returnType` and `resultType` should be identical (both derived from the same specialization), so the change is a no-op. For polymorphic wrappers, `sig.returnType` will have `MVar CEcoValue` → `!eco.value`, which is correct. Any other cases?

2. **Should we add a debug assertion** that warns when `Types.monoTypeToAbi sig.returnType /= Types.monoTypeToAbi resultType`? This would help surface future mismatches early, but adds noise for the known wrapper case. Probably not worth it.

## Verification

1. **Rebuild compiler and regenerate MLIR** for JsArray tests (`JsArrayGetSetTest.elm`, `JsArrayMapFoldTest.elm`). Confirm:
   - Wrapper declarations still have `-> (!eco.value)` return types
   - Call sites now emit `-> (!eco.value)` instead of `-> i64`
   - MLIR verifier passes

2. **Run E2E tests:**
   ```bash
   cmake --build build --target full
   TEST_FILTER=JsArray cmake --build build --target check
   ```

3. **Smoke test monomorphic functions:** A function returning `Int` should still produce `-> i64` at call sites (since `sig.returnType = MInt` → `i64`).

4. **Full test suite:**
   ```bash
   cmake --build build --target check
   ```
