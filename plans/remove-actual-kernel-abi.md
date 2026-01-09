# Plan: Remove actualKernelAbi and Make Kernel ABIs Fully Type-Driven

## Status: COMPLETED

## Problem Statement

Currently, MLIR codegen has two sources of truth for kernel function ABIs:

1. **Automatic**: Derived from monomorphized Elm types via `kernelFuncSignatureFromType`
2. **Manual**: Hard-coded in `actualKernelAbi` table

This duplication creates maintenance burden and potential for inconsistencies. The manual table exists because historically we didn't trust the Elm type system to provide correct ABIs for certain kernels.

## Goal

**Remove `actualKernelAbi` entirely** and derive all kernel ABIs from the monomorphized Elm type using:
- `kernelFuncSignatureFromType` to extract parameter/return types from `MonoType`
- `monoTypeToMlir` to convert `MonoType` to MLIR types (per CGEN_012)

After this change:
- Non-polymorphic kernels use the ABI implied by their Elm `MonoType`
- Polymorphic kernels (Debug, VirtualDom, etc.) continue using all-`eco.value` ABI
- Any kernel whose C++ signature doesn't match the Elm type is a C++ bug, not a compiler concern

## Design Decisions

### No Prerequisites Check Needed

All functions in `actualKernelAbi` have **obviously monomorphic** Elm types in `elm/core` (Float/Int/Bool). Given:
- PostSolver populates kernel types from annotations/usage
- The monomorphizer rewrites `Can.Type` into `Mono.MFloat`, `Mono.MInt`, etc.
- Guardrails prevent type variables from escaping
- A "kernel type mini-solver" is already in place

No verification of Elm types is needed before implementation.

### Overlap Between `isPolymorphicKernel` and `actualKernelAbi`

Four functions appear in both: `fdiv`, `pow`, `modBy`, `remainderBy`.

**Current behavior**:
- `isPolymorphicKernel "Basics" name` returns `True` for these
- So the polymorphic branch wins and `actualKernelAbi` entries are **dead code**

**Decision**: Keep them polymorphic (status quo, safest)
- Leave them in `isPolymorphicKernel`
- Delete the dead `actualKernelAbi` entries
- Rely on intrinsics for all "normal" code; only exotic uses go through eco.value kernel ABI

### Intrinsics Path is Independent

The intrinsics path (`kernelIntrinsic`) is already fully type-driven:
- Takes `(home, name, argTypes : List MonoType, resultType)`
- Matches on `argTypes` to pick the right intrinsic (e.g., `add` with `[MInt,MInt]` → `eco.int.add`)
- Uses `unboxArgsForIntrinsic` based solely on intrinsic operand types
- Result type via `intrinsicResultMlirType`, not `actualKernelAbi`

**No changes needed** to the intrinsics path.

### C++ Side Expectations

Kernel C++ stubs and implementations have been aligned with Elm types. The `actualKernelAbi` entries match the obvious Elm types (e.g., `sqrt : Float -> Float`), which match C++ prototypes.

**No widespread C++ changes expected.**

## Implementation Steps

### Step 1: Simplify kernel call generation in `generateCall`

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

**Location**: `generateCall` function, `Mono.MonoVarKernel _ home name funcType` branch, the `else` clause after `isPolymorphicKernel` check.

**Current code** (approximately lines 3133-3188):
```elm
else
    -- Generic kernel ABI path
    let
        elmSig : FuncSignature
        elmSig =
            kernelFuncSignatureFromType funcType

        sig : FuncSignature
        sig =
            case actualKernelAbi home name of
                Just abi ->
                    abi

                Nothing ->
                    elmSig

        ( boxOps, argVarPairs, ctx1b ) =
            boxToMatchSignatureTyped ctx1 argsWithTypes sig.paramTypes

        ...

        kernelResultType =
            monoTypeToMlir sig.returnType

        ...

        elmResultType =
            monoTypeToMlir elmSig.returnType

        needsBoxing =
            isEcoValueType elmResultType && not (isEcoValueType kernelResultType)
    in
    if needsBoxing then
        -- result boxing path
    else
        -- normal path
```

**New code**:
```elm
else
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

**Changes**:
- Remove `actualKernelAbi` lookup
- Remove `sig` variable (use `elmSig` directly)
- Remove `kernelResultType` vs `elmResultType` distinction
- Remove `needsBoxing` branch - result type is always from `elmSig`

### Step 2: Simplify `registerKernelCall`

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

**Location**: `registerKernelCall` function (approximately lines 543-590)

**Current code**:
```elm
registerKernelCall : Context -> String -> List MlirType -> MlirType -> Context
registerKernelCall ctx name callSiteArgTypes _ =
    let
        ( moduleName, funcName ) =
            parseKernelName name

        ( argTypes, returnType ) =
            if isPolymorphicKernel moduleName funcName then
                ( List.map (\_ -> ecoValue) callSiteArgTypes
                , ecoValue
                )
            else
                case actualKernelAbi moduleName funcName of
                    Just sig ->
                        ( List.map monoTypeToMlir sig.paramTypes
                        , monoTypeToMlir sig.returnType
                        )

                    Nothing ->
                        crash ("Missing kernel ABI for: " ++ ...)
    in
    ...
```

**New code**:
```elm
{-| Register a kernel function call, tracking it for declaration generation.

The canonical signature for a kernel is taken directly from the call site.
Subsequent calls to the same kernel name must use exactly the same argument
and result MLIR types, or we crash with a mismatch error.

This keeps declaration generation in sync with the ABI chosen at the call
site (which is derived from the Elm MonoType via monoTypeToMlir).
-}
registerKernelCall : Context -> String -> List MlirType -> MlirType -> Context
registerKernelCall ctx name callSiteArgTypes callSiteReturnType =
    case Dict.get name ctx.kernelDecls of
        Nothing ->
            { ctx
                | kernelDecls =
                    Dict.insert name ( callSiteArgTypes, callSiteReturnType ) ctx.kernelDecls
            }

        Just ( existingArgs, existingReturn ) ->
            if existingArgs == callSiteArgTypes && existingReturn == callSiteReturnType then
                ctx

            else
                crash
                    ("Kernel signature mismatch for "
                        ++ name
                        ++ ": existing ("
                        ++ Debug.toString existingArgs
                        ++ " -> "
                        ++ Debug.toString existingReturn
                        ++ ") vs new ("
                        ++ Debug.toString callSiteArgTypes
                        ++ " -> "
                        ++ Debug.toString callSiteReturnType
                        ++ ")"
                    )
```

**Changes**:
- Remove `parseKernelName` call
- Remove `isPolymorphicKernel` check
- Remove `actualKernelAbi` lookup
- Trust the call-site types directly
- Use `callSiteReturnType` parameter (was ignored before)

### Step 3: Delete `actualKernelAbi`

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

**Location**: After `isPolymorphicKernel` definition (approximately lines 339-422)

**Action**: Delete the entire `actualKernelAbi` function and its docstring:
```elm
{-| Get the actual C ABI signature for known kernel functions.
...
-}
actualKernelAbi : String -> String -> Maybe FuncSignature
actualKernelAbi home name =
    case home of
        "Basics" ->
            case name of
                "fdiv" -> ...
                ...
        _ ->
            Nothing
```

### Step 4: Delete `parseKernelName` (optional cleanup)

**File**: `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`

**Location**: Lines 525-535

**Action**: Delete the function if no longer used:
```elm
{-| Parse a kernel function name like "Elm_Kernel_VirtualDom_text" into (moduleName, funcName).
...
-}
parseKernelName : String -> ( String, String )
parseKernelName name =
    ...
```

**Verification**: Search for other uses of `parseKernelName` before deleting.

### Step 5: Update related docstrings

Update any docstrings that reference `actualKernelAbi`:
- `isPolymorphicKernel` docstring may reference it
- Module-level documentation if present

## Testing

1. **Build the compiler**: Ensure it compiles without errors
2. **Run existing test suite**: `./build/test/test` - ensure all tests pass
3. **Run Elm integration tests**: Test cases using Basics math functions
4. **Spot check generated MLIR** for a test case calling these functions:
   - Argument types should match Elm's monomorphized types
   - Return types should match Elm's monomorphized types

## Risks and Mitigations

| Risk | Mitigation |
|------|------------|
| C++ kernel signatures don't match expected ABI | C++ side should already match; this is the correct fix location if issues arise |
| Polymorphic kernels accidentally use type-driven ABI | `isPolymorphicKernel` check remains unchanged |

## Follow-up Work (out of scope)

1. Add compile-time assertion that non-polymorphic kernel `funcType` contains no `MVar`s
2. Consider removing `isPolymorphicKernel` if polymorphism can be detected from types
3. Document the type-driven kernel ABI in design docs
4. Consider removing `fdiv`, `pow`, `modBy`, `remainderBy` from `isPolymorphicKernel` to use type-driven ABI

## Files Changed

- `compiler/src/Compiler/Generate/CodeGen/MLIR.elm`
  - Modify `generateCall` (Step 1)
  - Modify `registerKernelCall` (Step 2)
  - Delete `actualKernelAbi` (Step 3)
  - Delete `parseKernelName` (Step 4, optional)
  - Update docstrings (Step 5)

## Related Invariants

- **CGEN_012**: monoTypeToMlir maps primitive MonoTypes to unboxed MLIR types; all others to eco.value
- **CGEN_011**: Every function referenced by eco.call must have func.func declaration
