# Plan: Let-Bound Higher-Order Argument Specialization

## Problem

When a let-bound polymorphic function (e.g. `identity`) is passed **as an argument** to another function (e.g. `apply identity 42`), the monomorphizer fails to specialize it. The local's canonical type variables stay unresolved because `specializeExpr` for `VarLocal` only sees the **outer** substitution, which has no bindings for the local's own type variables.

By contrast, when a let-bound function is the **callee** (e.g. `identity 42`), the call-site unification in the `TOpt.Call` handler produces a `callSubst` that refines its type and routes through `getOrCreateLocalInstance`. The "local as argument" path has no such refinement.

## Goal

Extend the existing `processCallArgs` / `resolveProcessedArgs` pipeline (the "pending arg" pattern already used for accessors and number-boxed kernels) so that let-bound functions passed as call arguments get specialized using the callee's parameter type at that slot.

---

## Step-by-Step Plan

### Step 1: Add `unifyExtend` to `TypeSubst.elm`

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm`

- Add `unifyExtend` to the module's export list (line 4, alongside `unify` and `unifyFuncCall`).
- Define the function (near `unify` at line 61):
  ```elm
  unifyExtend : Can.Type -> Mono.MonoType -> Substitution -> Substitution
  unifyExtend canType monoType baseSubst =
      unifyHelp canType monoType baseSubst
  ```
  This is a thin wrapper that exposes the existing `unifyHelp` publicly, letting callers extend an existing substitution with additional unification constraints (Can.Type vs MonoType).

**Rationale:** `unifyHelp` already does exactly what we need (it extends a subst). We just need a public entry point. `unify` starts from `Dict.empty`; `unifyFuncCall` is specialized for call-site shape. `unifyExtend` is the general "extend" form.

### Step 2: Add `LocalFunArg` to `ProcessedArg`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm` (line 49-52)

Extend the type:
```elm
type ProcessedArg
    = ResolvedArg Mono.MonoExpr
    | PendingAccessor A.Region Name Can.Type
    | PendingKernel A.Region String String Can.Type
    | LocalFunArg Name Can.Type
```

`LocalFunArg` carries:
- `Name` — the local function's name (e.g. `"identity"`)
- `Can.Type` — its canonical type (the polymorphic scheme, e.g. `a -> a`)

### Step 3: Intercept local function args in `processCallArgs`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`, function `processCallArgs` (lines 1325-1380)

In the catch-all `_ ->` branch, add cases for `TOpt.VarLocal` and `TOpt.TrackedVarLocal` **before** the fallthrough. When the name is a `localMulti` target, emit `LocalFunArg` instead of eagerly specializing:

```elm
TOpt.VarLocal name canType ->
    if isLocalMultiTarget name st then
        let
            monoType =
                Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
        in
        ( LocalFunArg name canType :: accArgs
        , monoType :: accTypes
        , st
        )
    else
        let
            ( monoExpr, st1 ) = specializeExpr arg subst st
        in
        ( ResolvedArg monoExpr :: accArgs
        , Mono.typeOf monoExpr :: accTypes
        , st1
        )

TOpt.TrackedVarLocal _ name canType ->
    -- Identical to VarLocal: region info is irrelevant to specialization;
    -- only name and canonical type matter.
    if isLocalMultiTarget name st then
        let
            monoType =
                Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
        in
        ( LocalFunArg name canType :: accArgs
        , monoType :: accTypes
        , st
        )
    else
        let
            ( monoExpr, st1 ) = specializeExpr arg subst st
        in
        ( ResolvedArg monoExpr :: accArgs
        , Mono.typeOf monoExpr :: accTypes
        , st1
        )
```

**Key detail:** For argTypes (used later in `unifyFuncCall`), we still contribute `applySubst subst canType` — the outer-substitution-applied type. This is the same quality of type info that other pending args contribute. The real refinement happens in `resolveProcessedArg`.

### Step 4: Handle `LocalFunArg` in `resolveProcessedArg`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`, function `resolveProcessedArg` (lines 1395-1478)

Add a new case branch:

```elm
LocalFunArg name canType ->
    case maybeParamType of
        Just paramType ->
            case paramType of
                Mono.MFunction _ _ ->
                    -- paramType is structurally a function: refine the local.
                    let
                        refinedSubst =
                            TypeSubst.unifyExtend canType paramType subst

                        funcMonoType =
                            Mono.forceCNumberToInt
                                (TypeSubst.applySubst refinedSubst canType)
                    in
                    if isLocalMultiTarget name state then
                        let
                            ( freshName, state1 ) =
                                getOrCreateLocalInstance
                                    name funcMonoType refinedSubst state
                        in
                        ( Mono.MonoVarLocal freshName funcMonoType, state1 )
                    else
                        ( Mono.MonoVarLocal name funcMonoType, state )

                _ ->
                    -- Param is MVar/CEcoValue/CNumber or other non-function:
                    -- no structural function info available, fall back.
                    let
                        monoType =
                            Mono.forceCNumberToInt
                                (TypeSubst.applySubst subst canType)
                    in
                    ( Mono.MonoVarLocal name monoType, state )

        Nothing ->
            -- No param info (oversaturation / weird staging); fall back.
            let
                monoType =
                    Mono.forceCNumberToInt
                        (TypeSubst.applySubst subst canType)
            in
            ( Mono.MonoVarLocal name monoType, state )
```

**How it works for `apply identity 42`:**
1. `paramType` for arg0 = `MFunction [MInt] MInt` (from callee `apply`'s unified signature).
2. `canType` for `identity` = `a -> a`.
3. `unifyExtend (a -> a) (MFunction [MInt] MInt) callSubst` binds `a -> MInt`.
4. `funcMonoType` becomes `MFunction [MInt] MInt`.
5. `getOrCreateLocalInstance "identity" (MFunction [MInt] MInt) refinedSubst` creates instance `"identity"` (index 0, keeps original name) or `"identity$1"` etc.
6. The argument expression becomes `MonoVarLocal "identity" (MFunction [MInt] MInt)`.

### Step 5: Add test cases to `SpecializePolyLetCases.elm`

**File:** `compiler/tests/SourceIR/SpecializePolyLetCases.elm`

Add new test case(s) for the specific pattern: **named let-bound function passed as argument**.

Existing tests (`applyMulti`, `twiceMulti`) use **inline lambdas** as the function argument, not named locals. We need:

```
identityAsArg (single instantiation):
    let
        identity x = x
        apply f x = f x
    in
    apply identity 42
```

```
identityAsArgMulti (multiple instantiations):
    let
        identity x = x
        apply f x = f x
    in
    (apply identity 42, apply identity "hello")
```

These test cases should verify:
- `identity` gets a concrete monomorphic type (`Int -> Int` or `String -> String`)
- No `MVar` / `CEcoValue` remains in the specialized instance's type
- Multiple uses produce multiple instances via `localMulti`

### Step 6: Run compiler tests

```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

Verify all existing tests pass plus the new ones.

### Step 7: Run E2E backend tests

```bash
cmake --build build --target check
```

Verify no regressions in the MLIR/LLVM pipeline.

---

## Resolved Design Decisions

### TrackedVarLocal parity
**Decision:** Treat `TrackedVarLocal` identically to `VarLocal`. The region info on `TrackedVarLocal` is irrelevant to specialization; only the name and canonical type matter. This mirrors the existing callee path (lines 970-975) which handles both identically.

### Subst composition / extra bindings from the callee
**Decision:** Safe to store `refinedSubst` (which contains callee's type variable bindings as extras) in `getOrCreateLocalInstance`. When the `Let` handler later does `mergedSubst = Dict.union info.subst subst`, the left-biased union ensures `refinedSubst`'s bindings win. Extra bindings for type variables not present in the local's canonical type are never looked up during `applySubst` and are harmless dead entries. The critical property is that the local's own type variables are correctly bound — which `unifyExtend canType paramType subst` guarantees.

### Non-function paramType
**Decision:** Only attempt refinement when `paramType` is structurally `MFunction`. There is no `CFunction` constraint in `MonoType` — function-ness is always structural. If `paramType` is `MVar _ CEcoValue` or `MVar _ CNumber`, we fall back to the outer subst (no refinement possible). This matches the accessor pattern which also insists on structural function/record types.

### Partially applied locals
**Decision:** No special handling needed.
- Direct partial application (`apply (f 1) x`): `f 1` is a `TOpt.Call`, not a `VarLocal`, so our `VarLocal`-keyed logic never fires. The inner call goes through the existing callee path.
- Bound partial application (`let p = f 1 in apply p x`): `p` appears as a `VarLocal` with a function canonical type. The `Let` handler already pushes a `localMulti` entry for it (because `defCanType` is `TLambda`). Our new logic correctly specializes `p` according to the expected param type, which is exactly right.

## Confirmed Assumptions

- **`isLocalMultiTarget` stability:** Between `processCallArgs` and `resolveProcessedArg`, the `localMulti` stack doesn't change for the name in question. `processCallArgs` doesn't push/pop the stack, and `resolveProcessedArgs` only calls `getOrCreateLocalInstance` which updates existing entries but doesn't remove them.

- **argTypes quality:** Using `applySubst subst canType` (outer subst) for the argType contribution to `unifyFuncCall` is sufficient. The callee's unification constrains the param type independently, and we use that refined param type in `resolveProcessedArg`.

- **No new imports needed:** `TypeSubst.unifyExtend` is the only new cross-module dependency. `Specialize.elm` already imports `TypeSubst`.

- **No impact on non-local-multi paths:** Local variables that are not `localMulti` targets continue through the existing `specializeExpr` -> `ResolvedArg` path unchanged.
