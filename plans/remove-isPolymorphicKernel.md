# Plan: Remove isPolymorphicKernel and Move Polymorphism to Monomorphizer

## Status: COMPLETED

## Problem Statement

After removing `actualKernelAbi`, MLIR codegen still has `isPolymorphicKernel` - a name-based table that determines whether a kernel should use all-boxed `!eco.value` ABI. This violates the principle of "correctness by ignorance" - MLIR shouldn't need to know which kernels are polymorphic.

## Goal

Move all polymorphism decisions to the **monomorphizer** via `MonoType`, so MLIR is completely ignorant of which kernels are polymorphic:

1. Introduce `isAlwaysPolymorphicKernel` in `Monomorphize.elm`
2. For those kernels, preserve type variables in `MonoType` (don't apply substitutions)
3. MLIR derives ABI purely from `MonoType` via `monoTypeToMlir`:
   - `MVar` → `!eco.value` (polymorphic kernels naturally get all-boxed ABI)
   - Primitives → unboxed types

## Design Decisions

### Why This Works

1. **Heap types already work**: Types like `Url`, `VirtualDom`, `Task`, `List a`, `Maybe a` are represented as non-primitive `MonoType` constructors, which `monoTypeToMlir` already maps to `!eco.value`.

2. **Only truly polymorphic kernels need special handling**: Kernels like `Utils.compare`, `Utils.equal`, `Basics.add` (when `number` leaks through) need preserved type variables.

3. **Debug already handled**: `VarDebug` already has special handling in the monomorphizer that preserves type variables.

### Minimal Kernel Whitelist

Only kernels that **absolutely require** polymorphic ABI at the C level:

```elm
isAlwaysPolymorphicKernel : String -> String -> Bool
isAlwaysPolymorphicKernel home name =
    case home of
        "Utils" ->
            -- Polymorphic over comparable/equatable/appendable
            name == "compare" || name == "equal" || name == "append"
                || name == "lt" || name == "le" || name == "gt" || name == "ge"
                || name == "notEqual"

        "Basics" ->
            -- Fallback when `number` leaks through monomorphization
            name == "add" || name == "sub" || name == "mul" || name == "pow"

        _ ->
            False
```

**Not listed** (don't need special handling):
- `Debug.*` - already handled via `VarDebug` special case
- `VirtualDom.*`, `Scheduler.*`, `Json.*`, etc. - heap types already map to `!eco.value`

## Implementation Steps

### Step 1: Add `isAlwaysPolymorphicKernel` in Monomorphize.elm

**File**: `compiler/src/Compiler/Generate/Monomorphize.elm`

**Location**: Near other helper functions, before `specializeExpr`

**Code**:
```elm
{-| Kernels whose C ABI must remain polymorphic (all boxed eco.value).

For these, we preserve type variables in the function type so that
monoTypeToMlir maps their parameters/results to !eco.value.
-}
isAlwaysPolymorphicKernel : String -> String -> Bool
isAlwaysPolymorphicKernel home name =
    case home of
        "Utils" ->
            name == "compare"
                || name == "equal"
                || name == "append"
                || name == "lt"
                || name == "le"
                || name == "gt"
                || name == "ge"
                || name == "notEqual"

        "Basics" ->
            name == "add"
                || name == "sub"
                || name == "mul"
                || name == "pow"

        _ ->
            False
```

### Step 2: Update non-call VarKernel in specializeExpr

**File**: `compiler/src/Compiler/Generate/Monomorphize.elm`

**Location**: In `specializeExpr`, the `TOpt.VarKernel` branch

**Current code**:
```elm
TOpt.VarKernel region home name canType ->
    let
        monoType =
            applySubst subst canType
    in
    ( Mono.MonoVarKernel region home name monoType, state )
```

**New code**:
```elm
TOpt.VarKernel region home name canType ->
    let
        monoType =
            if isAlwaysPolymorphicKernel home name then
                -- Preserve type variables so they map to !eco.value
                applySubst Dict.empty canType
            else
                -- Fully specialize the function type
                applySubst subst canType
    in
    ( Mono.MonoVarKernel region home name monoType, state )
```

### Step 3: Update VarKernel calls in specializeExpr

**File**: `compiler/src/Compiler/Generate/Monomorphize.elm`

**Location**: In `specializeExpr`, the `TOpt.Call` branch, `TOpt.VarKernel` callee case

**Current code**:
```elm
TOpt.VarKernel funcRegion home name funcCanType ->
    let
        argTypes =
            List.map Mono.typeOf monoArgs

        callSubst =
            unifyFuncCall funcCanType argTypes canType subst

        resultMonoType =
            applySubst callSubst canType

        funcMonoType =
            applySubst callSubst funcCanType

        monoFunc =
            Mono.MonoVarKernel funcRegion home name funcMonoType
    in
    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state1 )
```

**New code**:
```elm
TOpt.VarKernel funcRegion home name funcCanType ->
    let
        argTypes =
            List.map Mono.typeOf monoArgs

        callSubst =
            unifyFuncCall funcCanType argTypes canType subst

        resultMonoType =
            applySubst callSubst canType

        funcMonoType =
            if isAlwaysPolymorphicKernel home name then
                -- Preserve type variables in the function type so that
                -- its ABI is all !eco.value
                applySubst Dict.empty funcCanType
            else
                -- Fully specialize the function type
                applySubst callSubst funcCanType

        monoFunc =
            Mono.MonoVarKernel funcRegion home name funcMonoType
    in
    ( Mono.MonoCall region monoFunc monoArgs resultMonoType, state1 )
```

### Step 4: Delete isPolymorphicKernel from MLIR.elm

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

**Location**: After `kernelFuncSignatureFromType`, before `isTypeVar`

**Action**: Delete the entire `isPolymorphicKernel` function and its docstring.

### Step 5: Verify generateCall uses pure type-driven path

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

**Location**: `generateCall`, `Mono.MonoVarKernel` branch

Ensure the `Nothing` branch (after intrinsics check) is the simplified type-driven version with no `isPolymorphicKernel` check:

```elm
Nothing ->
    -- Generic kernel ABI path derived solely from MonoType
    let
        elmSig : FuncSignature
        elmSig =
            kernelFuncSignatureFromType funcType

        ( boxOps, argVarPairs, ctx1b ) =
            boxToMatchSignatureTyped ctx1 argsWithTypes elmSig.paramTypes

        ( resVar, ctx2 ) =
            freshVar ctx1b

        kernelName : String
        kernelName =
            "Elm_Kernel_" ++ home ++ "_" ++ name

        resultMlirType : MlirType
        resultMlirType =
            monoTypeToMlir elmSig.returnType

        ( ctx3, callOp ) =
            ecoCallNamed ctx2 resVar kernelName argVarPairs resultMlirType
    in
    { ops = argOps ++ boxOps ++ [ callOp ]
    , resultVar = resVar
    , resultType = resultMlirType
    , ctx = ctx3
    }
```

### Step 6: Verify registerKernelCall is type-agnostic

Already done in previous refactoring - just verify no `isPolymorphicKernel` references remain.

## Testing

1. **Build compiler**: Ensure no compile errors
2. **Run test suite**: `./build/test/test`
3. **Specifically test**:
   - Debug.log (uses VarDebug path)
   - Utils.compare, Utils.equal (polymorphic)
   - Basics arithmetic (intrinsics for concrete types, kernel for polymorphic)
   - VirtualDom functions (heap types → eco.value)

## Invariants After This Change

| Kernel Category | MonoType | MLIR Type |
|----------------|----------|-----------|
| Always-polymorphic (Utils.compare, etc.) | `MVar` preserved | `!eco.value` |
| Debug.* | `MVar` preserved (via VarDebug) | `!eco.value` |
| Heap-typed (VirtualDom, Json, etc.) | Non-primitive constructors | `!eco.value` |
| Primitive-typed (Basics.sqrt, etc.) | `MInt`, `MFloat`, etc. | `i64`, `f64`, etc. |

## Files Changed

- `compiler/src/Compiler/Generate/Monomorphize.elm`
  - Add `isAlwaysPolymorphicKernel` (Step 1)
  - Update `TOpt.VarKernel` branch (Step 2)
  - Update `TOpt.Call` with `VarKernel` callee (Step 3)

- `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`
  - Delete `isPolymorphicKernel` (Step 4)
  - Verify `generateCall` is type-driven (Step 5)
  - Verify `registerKernelCall` is type-agnostic (Step 6)

## Related Invariants

- **CGEN_012**: monoTypeToMlir maps primitive MonoTypes to unboxed MLIR types; all others to eco.value
- **MONO_003**: MVar with CEcoValue constraint → boxed eco.value
- **MONO_009**: Debug kernel calls preserve type variables via empty substitution
