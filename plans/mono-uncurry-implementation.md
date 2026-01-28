# Mono-Uncurry Implementation Plan (Option A)

## Overview

This plan implements "Option A" from `design_docs/mono-uncurry.md`: **flatten function types AND lambda values in monomorphization** to ensure the uncurried calling convention is consistent throughout the compiler.

### The Problem

`TypeSubst.applySubst` already flattens `TLambda` chains into `MFunction [args] ret`, but lambda *values* in `specializeExpr` are still processed with only their immediate parameters. This creates a mismatch where:
- A function type says "expects 3 arguments"
- But the closure only has 1 parameter (returning another closure)

### The Solution

Peel nested lambda chains into a single `MonoClosure` with all parameters combined, eliminating staged lambda boundaries. Partial application is then represented **only** via PAPs (`eco.papCreate`/`eco.papExtend`), not via nested closures.

---

## Step-by-Step Implementation

### Step 1: Add `peelFunctionChain` helper in Specialize.elm

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Location:** Add after imports, before `specializeNode`

**Implementation:**

```elm
{-| Peel nested Function/TrackedFunction expressions into a flat parameter list.

This helper recursively descends through nested lambda expressions, collecting
all parameters into a single list. It handles both Function and TrackedFunction
variants uniformly, converting TrackedFunction's Located names to plain names.

Returns (allParams, finalBody) where:
- allParams: All parameters from the entire lambda chain, in order
- finalBody: The first non-function expression encountered
-}
peelFunctionChain : TOpt.Expr -> ( List ( Name, Can.Type ), TOpt.Expr )
peelFunctionChain expr =
    case expr of
        TOpt.Function params body _ ->
            let
                ( moreParams, finalBody ) =
                    peelFunctionChain body
            in
            ( params ++ moreParams, finalBody )

        TOpt.TrackedFunction params body _ ->
            let
                -- Convert Located names to plain names
                plainParams =
                    List.map (\( locName, ty ) -> ( A.toValue locName, ty )) params

                ( moreParams, finalBody ) =
                    peelFunctionChain body
            in
            ( plainParams ++ moreParams, finalBody )

        _ ->
            ( [], expr )
```

**Key points:**
- Handles both `TOpt.Function` and `TOpt.TrackedFunction` uniformly
- Supports mixed chains (Function containing TrackedFunction or vice versa)
- Converts `A.Located Name` to plain `Name` for TrackedFunction params

---

### Step 2: Create shared helper for Function/TrackedFunction specialization

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Rationale:** The `TOpt.Function` and `TOpt.TrackedFunction` cases have identical logic after peeling. Extract this into a shared helper to avoid duplication.

**Implementation:**

```elm
{-| Specialize a lambda expression (Function or TrackedFunction) by peeling
nested lambdas into a single MonoClosure.

This is the core Option A transformation: nested lambdas become a single
uncurried closure. Partial application is represented only via PAPs downstream.
-}
specializeLambda :
    TOpt.Expr  -- The lambda expression (Function or TrackedFunction)
    -> Can.Type  -- The canonical type of the outer lambda
    -> Substitution
    -> MonoState
    -> ( Mono.MonoExpr, MonoState )
specializeLambda lambdaExpr canType subst state =
    let
        monoType =
            TypeSubst.applySubst subst canType

        funcTypeParams =
            TypeSubst.extractParamTypes monoType

        -- Peel entire lambda chain
        ( allParams, finalBody ) =
            peelFunctionChain lambdaExpr

        -- Assert param count matches (compiler bug if not)
        _ =
            if List.length allParams /= List.length funcTypeParams then
                Utils.Crash.crash
                    ("Lambda peeling mismatch: "
                        ++ String.fromInt (List.length allParams)
                        ++ " params but type has "
                        ++ String.fromInt (List.length funcTypeParams)
                    )
            else
                ()

        -- Derive param types using funcTypeParams (single source of truth)
        deriveParamType : Int -> ( Name, Can.Type ) -> ( Name, Mono.MonoType )
        deriveParamType idx ( name, paramCanType ) =
            let
                funcParamTypeAtIdx =
                    List.drop idx funcTypeParams |> List.head

                substType =
                    TypeSubst.applySubst subst paramCanType

                finalType =
                    case funcParamTypeAtIdx of
                        Just funcParamType ->
                            case paramCanType of
                                Can.TVar _ ->
                                    funcParamType

                                _ ->
                                    case substType of
                                        Mono.MVar _ _ ->
                                            funcParamType

                                        _ ->
                                            substType

                        Nothing ->
                            substType
            in
            ( name, finalType )

        -- Map over ALL peeled params
        monoParams =
            List.indexedMap deriveParamType allParams

        lambdaId =
            Mono.AnonymousLambda state.currentModule state.lambdaCounter

        -- Update varTypes with ALL params
        newVarTypes =
            List.foldl
                (\( name, monoParamType ) vt ->
                    Dict.insert identity name monoParamType vt
                )
                state.varTypes
                monoParams

        stateWithLambda =
            { state
                | lambdaCounter = state.lambdaCounter + 1
                , varTypes = newVarTypes
            }

        -- Build augmentedSubst from ALL params
        augmentedSubst =
            List.foldl
                (\( ( _, paramCanType ), ( _, monoParamType ) ) s ->
                    case paramCanType of
                        Can.TVar varName ->
                            Dict.insert identity varName monoParamType s

                        _ ->
                            s
                )
                subst
                (List.map2 Tuple.pair allParams monoParams)

        -- Specialize the FINAL body (not intermediate)
        ( monoBody, stateAfter ) =
            specializeExpr finalBody augmentedSubst stateWithLambda

        -- Captures computed on final body with full param list
        captures =
            Closure.computeClosureCaptures monoParams monoBody

        closureInfo =
            { lambdaId = lambdaId
            , captures = captures
            , params = monoParams
            }
    in
    ( Mono.MonoClosure closureInfo monoBody monoType, stateAfter )
```

---

### Step 3: Update `specializeExpr` cases for Function/TrackedFunction

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Location:** Lines ~573-714 (both Function and TrackedFunction cases)

**Change both cases to use the shared helper:**

```elm
TOpt.Function params body canType ->
    specializeLambda (TOpt.Function params body canType) canType subst state

TOpt.TrackedFunction params body canType ->
    specializeLambda (TOpt.TrackedFunction params body canType) canType subst state
```

---

### Step 4: Replace `functionArity` with `countTotalArity` in MLIR Expr.elm

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Locations:** Three occurrences for `eco.papExtend remaining_arity`:

| Line | Current | Change to |
|------|---------|-----------|
| 1037 | `Types.functionArity funcType` | `Types.countTotalArity funcType` |
| 1697 | `Types.functionArity funcType` | `Types.countTotalArity funcType` |
| 1798 | `Types.functionArity funcType` | `Types.countTotalArity funcType` |

**Rationale:**
- `functionArity` counts arrow depth (1 per `MFunction` level)
- `countTotalArity` counts actual total arguments across all `MFunction` levels
- After type flattening, we need actual argument count for PAP semantics

**Do NOT change:** The `papCreate` arity computation in `generateClosure` (line ~710):
```elm
arity = numCaptured + List.length closureInfo.params
```
This is already correct because after our monomorphization fix, `closureInfo.params` will contain ALL parameters.

---

### Step 5: Verify `ensureCallableTopLevel` kernel wrapper handling

**File:** `compiler/src/Compiler/Generate/Monomorphize/Closure.elm`

**Location:** Lines 43-84, specifically the `MonoVarKernel` branch (lines 68-78)

**Current code analysis:**
```elm
( argTypes, retType ) =
    flattenFunctionType monoType  -- Line 46 - uses monoType for ALL branches
```

The `flattenFunctionType` is called on `monoType` before the case statement, so all branches (including `MonoVarKernel`) use `monoType`-derived params.

**Potential issue:** For kernel wrappers, we should derive wrapper params from `kernelAbiType` for ABI stability.

**Recommended fix:** Move the `flattenFunctionType` call inside the `MonoVarKernel` branch to use `kernelAbiType`:

```elm
Mono.MonoVarKernel region home name kernelAbiType ->
    let
        -- Use kernelAbiType for wrapper params (ABI stability)
        ( wrapperArgTypes, wrapperRetType ) =
            flattenFunctionType kernelAbiType
    in
    makeAliasClosure
        (Mono.MonoVarKernel region home name kernelAbiType)
        region
        wrapperArgTypes
        wrapperRetType
        monoType
        state
```

---

### Step 6: Strengthen MONO_016 invariant

**File:** `design_docs/invariants.csv`

**Current MONO_016:**
> When creating uncurried wrapper closures for functions that return functions the wrapper must generate nested MonoCall expressions that respect the original curried parameter structure...

**New MONO_016 (Option A invariant):**
> For every MonoClosure with type MFunction, List.length closureInfo.params must equal Types.countTotalArity monoType. No MonoClosure may have fewer params than the total arity of its MonoType.

**Test file to update:** `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm`

This test currently verifies MONO_016's original semantics. Update it to verify the new Option A invariant instead.

---

### Step 7: Fix CGEN_052 test logic in PapExtendArity.elm

**File:** `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity.elm`

**Current bug:** The test tracks the wrong arities:
- For `papCreate`: stores `arity` attribute directly
- For `papExtend`: stores `remaining_arity` attribute as result's arity

**Correct semantics per dialect:**
- For `papCreate`: result's remaining arity = `arity - num_captured`
- For `papExtend`: result's remaining arity = `remaining_arity - numNewArgs`

**Fix `buildPapArityMap`:**

```elm
buildPapArityMap : MlirModule -> Dict String Int
buildPapArityMap mlirModule =
    let
        allOps =
            walkAllOps mlirModule

        processOp : MlirOp -> Dict String Int -> Dict String Int
        processOp op map =
            if op.name == "eco.papCreate" then
                -- papCreate: remaining = arity - num_captured
                case ( List.head op.results, getIntAttr "arity" op, getIntAttr "num_captured" op ) of
                    ( Just ( resultName, _ ), Just arity, Just numCaptured ) ->
                        let
                            remaining = arity - numCaptured
                        in
                        Dict.insert resultName remaining map

                    _ ->
                        map

            else if op.name == "eco.papExtend" then
                -- papExtend: result remaining = remaining_arity - numNewArgs
                case ( List.head op.results, getIntAttr "remaining_arity" op ) of
                    ( Just ( resultName, _ ), Just remainingArity ) ->
                        let
                            numNewArgs = List.length op.operands - 1
                            resultRemaining = remainingArity - numNewArgs
                        in
                        -- Only add if still a PAP (remaining > 0)
                        if resultRemaining > 0 then
                            Dict.insert resultName resultRemaining map
                        else
                            map

                    _ ->
                        map

            else
                map
    in
    List.foldl processOp Dict.empty allOps
```

**Update check logic in `checkPapExtendOp`:**

The verification logic should check that `remaining_arity` attribute equals the source PAP's remaining arity (from our corrected map). The current logic is correct for this part; we just need to ensure the map is built correctly.

---

### Step 8: Add MONO_016 closure arity check

**New file:** `compiler/tests/Compiler/Generate/MonoClosureArityTest.elm`

**Or update:** `compiler/tests/Compiler/Generate/MonoFunctionArityTest.elm` (currently MONO_012)

Add a check that verifies Option A's core guarantee:

```elm
{-| MONO_016 (Option A): Every MonoClosure's param count equals its type's total arity.
-}
checkClosureParamCount : Mono.MonoExpr -> List Violation
checkClosureParamCount expr =
    case expr of
        Mono.MonoClosure closureInfo _ monoType ->
            let
                paramCount = List.length closureInfo.params
                typeArity = Types.countTotalArity monoType
            in
            if paramCount /= typeArity then
                [ { message =
                        "MONO_016 violation: closure has "
                            ++ String.fromInt paramCount
                            ++ " params but type arity is "
                            ++ String.fromInt typeArity
                  }
                ]
            else
                -- Recurse into body
                checkClosureParamCount (Mono.bodyOf closureInfo)

        -- Other cases: recurse into sub-expressions
        _ ->
            foldMonoExpr checkClosureParamCount expr
```

---

### Step 9: Run tests and verify

**Commands:**

```bash
# Front-end compiler tests
cd compiler && npx elm-test --fuzz 1

# Full E2E tests (rebuilds compiler, runs all tests)
cmake --build build --target full

# Quick check after C++ changes only
cmake --build build --target check

# Filter to specific test categories
TEST_FILTER=elm cmake --build build --target check
TEST_FILTER=codegen cmake --build build --target check
```

**Expected outcomes:**
1. All existing tests should pass (semantics preserved)
2. New MONO_016 check catches any remaining staged lambda issues
3. Fixed CGEN_052 validates PAP arity tracking correctly

---

## Resolved Questions

### Q1: Mixed Function/TrackedFunction chains
**Answer:** Yes, mixed chains can occur. `peelFunctionChain` handles both variants uniformly by pattern matching on either and converting `A.Located Name` to plain `Name` for TrackedFunction.

### Q2: Param type derivation for peeled lambdas
**Answer:** Rely entirely on the flattened `funcTypeParams` from the outer type. The outer lambda's `Can.Type` (after substitution) is the single source of truth. Inner lambda type annotations are ignored for primary typing logic.

### Q3: Recursion and mutual recursion
**Answer:** Peeling is safe for recursion. It only affects closure representation, not recursive call structure. Tail recursion (handled via `MonoTailFunc`) is unaffected since peeling only applies to closure-valued expressions.

### Q4: Captures across peeled lambdas
**Answer:** `computeClosureCaptures` works correctly after peeling. Variables that were captures of inner lambdas become explicit parameters of the peeled closure. Only truly external variables remain as captures. This is a benefit, not a problem.

### Q5: Test file locations
**Answer:** Found existing structure:
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArityTest.elm` - CGEN_052 test (needs logic fix)
- `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity.elm` - CGEN_052 check logic
- `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm` - MONO_016 test
- `compiler/tests/Compiler/Generate/MonoFunctionArityTest.elm` - MONO_012 test

### Q6: MONO_016 decision
**Answer:** Strengthen MONO_016 to the Option A invariant: "For every MonoClosure, param count must equal countTotalArity of its MonoType." Update `WrapperCurriedCallsTest.elm` accordingly.

### Q7: Shared helper vs duplicate code
**Answer:** Use a shared helper (`specializeLambda`) since the functionality is identical for both `TOpt.Function` and `TOpt.TrackedFunction` after peeling.

### Q8: Assertion mechanism
**Answer:** Use `Utils.Crash.crash` for the param count assertion.

---

## File Change Summary

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Add `peelFunctionChain`, add `specializeLambda` helper, update `TOpt.Function` and `TOpt.TrackedFunction` cases |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Replace 3 occurrences of `functionArity` with `countTotalArity` (lines 1037, 1697, 1798) |
| `compiler/src/Compiler/Generate/Monomorphize/Closure.elm` | Fix kernel wrapper param derivation to use `kernelAbiType` |
| `design_docs/invariants.csv` | Update MONO_016 definition to Option A invariant |
| `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity.elm` | Fix `buildPapArityMap` to track remaining arity correctly |
| `compiler/tests/Compiler/Generate/Monomorphize/WrapperCurriedCallsTest.elm` | Update to verify new MONO_016 semantics |
