# specializeLambda Two-Mode Implementation Plan

## Overview

This plan modifies `specializeLambda` to implement the MONO_016 invariant correctly with a two-mode approach:

1. **Fully Peelable (uncurried)**: Simple lambda chains like `\x -> \y -> \z -> body` are flattened into a single `MFunction [x,y,z] ret`
2. **Wrapper/Curried (staged)**: Lambdas separated by `let`/`case` like `\x -> let ... in \y -> body` preserve nested `MFunction [x] (MFunction [y] ret)` structure

### Current State

The current `specializeLambda` (lines 233-365 of `Specialize.elm`) always uses stage arity:
- Peels ALL syntactic params via `peelFunctionChain`
- Then uses `peelNParams outerStageArity` to get `effectiveParams`
- Special handling for `outerStageArity == 0` (non-function type)

This approach doesn't distinguish between simple chains (which should be uncurried) and wrappers (which should remain curried).

### What Must Change

The logic needs to first determine if the lambda is "fully peelable" (all syntactic params match the total flattened arity), then either:
- **If fully peelable**: Use uncurried `MFunction flatArgTypes flatRetType`, params = all peeled params
- **If not**: Use the nested `monoType0` with params from outer stage only

### Important: How Staged `applySubst` Affects Types

With the staged `TypeSubst.applySubst` (which builds `MFunction [argMono] resultMono` for each `TLambda`):

- A simple chain `\x -> \y -> \z -> body` produces `monoType0 = MFunction [a] (MFunction [b] (MFunction [c] ret))` — **NOT** `MFunction [a,b,c] ret`
- The flattened view `(flatArgTypes, flatRetType)` comes from `Closure.flattenFunctionType`, giving `([a,b,c], ret)` and `totalArity = 3`
- For wrappers like `\x -> let ... in \y -> body`, `monoType0 = MFunction [xTy] (MFunction [yTy] ret)`, and `peelFunctionChain` returns only `[x]` since it stops at the `let`

This means:
- In the **fully peelable** path: we use `flatArgTypes` (the flattened view) for the closure type
- In the **curried** path: `monoType0.args` has length 1 (single stage), which must exactly match `paramCount`

---

## Step-by-Step Implementation

### Step 1: Replace `specializeLambda` body

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

Replace lines 233-365 with the new two-mode logic:

```elm
specializeLambda lambdaExpr canType subst state =
    let
        -- Stage-aware MonoType (nested MFunction chain, no flattening)
        monoType0 : Mono.MonoType
        monoType0 =
            TypeSubst.applySubst subst canType

        -- Total flattened args & final return (for fully-peelable lambdas)
        ( flatArgTypes, flatRetType ) =
            Closure.flattenFunctionType monoType0

        totalArity : Int
        totalArity =
            List.length flatArgTypes

        -- Peel syntactic chain of lambdas (stops at let/case)
        ( allParams, finalBodyExpr ) =
            peelFunctionChain lambdaExpr

        paramCount : Int
        paramCount =
            List.length allParams
    in
    -- Guard: paramCount == 0 is a bug (caller invoked specializeLambda on non-lambda)
    if paramCount == 0 then
        Utils.Crash.crash "specializeLambda: called with non-lambda or zero-arg lambda; this should not happen"

    -- Guard: totalArity == 0 means non-function type
    -- This is defensive and should not occur in well-typed Elm code, since specializeLambda
    -- is only called on Function/TrackedFunction nodes which always have function types.
    -- We handle it by rebuilding an MFunction from the params as a fallback.
    else if totalArity == 0 then
        let
            -- Derive param types from canonical params
            monoParams =
                List.map (\( name, paramCanType ) -> ( name, TypeSubst.applySubst subst paramCanType )) allParams

            returnType =
                TypeSubst.applySubst subst (TOpt.typeOf finalBodyExpr)

            effectiveMonoType =
                Mono.MFunction (List.map Tuple.second monoParams) returnType

            lambdaId =
                Mono.AnonymousLambda state.currentModule state.lambdaCounter

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

            ( monoBody, stateAfter ) =
                specializeExpr finalBodyExpr augmentedSubst stateWithLambda

            captures =
                Closure.computeClosureCaptures monoParams monoBody

            closureInfo =
                { lambdaId = lambdaId
                , captures = captures
                , params = monoParams
                }
        in
        ( Mono.MonoClosure closureInfo monoBody effectiveMonoType, stateAfter )

    else
        -- Normal case: totalArity > 0 and paramCount > 0
        let
            -- Key decision: is this a simple lambda chain or a wrapper?
            isFullyPeelable : Bool
            isFullyPeelable =
                paramCount == totalArity

            -- Effective MonoType: uncurried for simple chains, nested for wrappers
            effectiveMonoType : Mono.MonoType
            effectiveMonoType =
                if isFullyPeelable then
                    Mono.MFunction flatArgTypes flatRetType
                else
                    monoType0

            -- Effective param types for type derivation
            effectiveParamTypes : List Mono.MonoType
            effectiveParamTypes =
                if isFullyPeelable then
                    flatArgTypes
                else
                    case monoType0 of
                        Mono.MFunction args _ ->
                            -- MONO_016: paramCount must EXACTLY match stage arg count
                            -- With staged applySubst, args has length 1 for each TLambda level,
                            -- so this checks that we have exactly one syntactic param per stage.
                            if paramCount /= List.length args then
                                Utils.Crash.crash
                                    ("specializeLambda: paramCount ("
                                        ++ String.fromInt paramCount
                                        ++ ") != stage arg count ("
                                        ++ String.fromInt (List.length args)
                                        ++ ") for lambda of type "
                                        ++ Debug.toString monoType0
                                    )
                            else
                                args

                        _ ->
                            -- monoType0 is MFunction since totalArity > 0; unreachable
                            Utils.Crash.crash "specializeLambda: monoType0 is not MFunction but totalArity > 0"

            deriveParamType : Int -> ( Name, Can.Type ) -> ( Name, Mono.MonoType )
            deriveParamType idx ( name, paramCanType ) =
                let
                    funcParamTypeAtIdx =
                        List.drop idx effectiveParamTypes |> List.head

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

            monoParams : List ( Name, Mono.MonoType )
            monoParams =
                List.indexedMap deriveParamType allParams

            -- MONO_016 assertion: closure params must match stage arity
            _ =
                let
                    stageArityCheck =
                        Types.stageParamTypes effectiveMonoType
                in
                if List.length monoParams /= List.length stageArityCheck then
                    Utils.Crash.crash
                        ("MONO_016 violation: closure has "
                            ++ String.fromInt (List.length monoParams)
                            ++ " params but effectiveMonoType has stage arity "
                            ++ String.fromInt (List.length stageArityCheck)
                        )
                else
                    ()

            lambdaId =
                Mono.AnonymousLambda state.currentModule state.lambdaCounter

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

            ( monoBody, stateAfter ) =
                specializeExpr finalBodyExpr augmentedSubst stateWithLambda

            captures =
                Closure.computeClosureCaptures monoParams monoBody

            closureInfo =
                { lambdaId = lambdaId
                , captures = captures
                , params = monoParams
                }
        in
        ( Mono.MonoClosure closureInfo monoBody effectiveMonoType, stateAfter )
```

### Step 2: Remove unused helpers

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

Delete the following functions that are no longer used:

| Lines | Function | Reason |
|-------|----------|--------|
| 105-113 | Comment block | Documents peelNParams which is being removed |
| 115-152 | `peelNParams` | No longer called; new logic uses `peelFunctionChain` directly |
| 155-171 | `rebuildLambdaChain` | Only used by `peelNParams` |
| 174-191 | `rebuildTrackedLambdaChain` | Only used by `peelNParams` |

### Step 3: Verify existing helpers remain correct

**No changes needed to:**

| File | Function | Reason |
|------|----------|--------|
| `TypeSubst.elm` | `applySubst` | Already does not flatten TLambda (line 256: `Mono.MFunction [ argMono ] resultMono`) |
| `Types.elm` | `stageArity`, `stageParamTypes` | Already exist and work correctly |
| `Closure.elm` | `flattenFunctionType` | Still needed for `isFullyPeelable` calculation |
| `Closure.elm` | `ensureCallableTopLevel` | Crashes on under-parameterized closures; with new `specializeLambda`, this crash becomes an invariant guard that should never fire |

---

## Key Semantic Changes

### Before (current implementation)
- Always uses `peelNParams outerStageArity` regardless of lambda structure
- Special handling for `outerStageArity == 0`
- Doesn't distinguish simple chains from wrappers
- Allows `paramCount < stageArity` by truncating

### After (two-mode implementation)
- **Simple chains** (`\x -> \y -> body`): `isFullyPeelable=true`, produces `MFunction [x,y] ret` with 2 params
- **Wrappers** (`\x -> let ... in \y -> body`): `isFullyPeelable=false`, produces `MFunction [x] (MFunction [y] ret)` with 1 param
- **Crashes on invalid cases**:
  - `paramCount == 0`: Bug at caller (not a lambda)
  - `paramCount != stageArity` in curried path: Type/syntax mismatch (compiler bug)
- **MONO_016 assertion**: Explicitly checks `length monoParams == length (Types.stageParamTypes effectiveMonoType)`

### Guard Cases (with crashes)

| Condition | Meaning | Action |
|-----------|---------|--------|
| `paramCount == 0` | Called on non-lambda | Crash - caller bug |
| `totalArity == 0` | Non-function type | Build MFunction from allParams (defensive, should be unreachable) |
| `paramCount != List.length args` (curried) | Type/syntax mismatch | Crash - compiler bug |
| MONO_016 check fails | Internal inconsistency | Crash - logic bug |

---

## Interaction with `ensureCallableTopLevel`

With this new `specializeLambda`:

**Fully peelable simple lambdas:**
- `effectiveMonoType = MFunction flatArgTypes flatRetType`
- `length monoParams == length flatArgTypes`
- `Types.stageArity effectiveMonoType == paramCount`
- `ensureCallableTopLevel` sees `closureInfo.params` count `== stageArity` and returns unchanged

**Wrapper lambdas:**
- `effectiveMonoType = monoType0 = MFunction [xTy] (MFunction [yTy] ret)`
- `monoParams = [(x, xTy)]`
- `Types.stageArity effectiveMonoType == 1 == paramCount`
- `ensureCallableTopLevel` sees `closureInfo.params` count `== stageArity` and returns unchanged

**Result:** The "under-parameterized closure" crash in `ensureCallableTopLevel` is no longer exercised for closures from `specializeLambda`. It becomes a pure invariant guard. This prevents the previous issue where `makeAliasClosureOverExpr` was wrapping already-closed expressions and dropping captures.

---

## MONO_016 Enforcement

The invariant states:
> "Simple directly-nested lambda chains are uncurried into a single flat MFunction stage while lambdas separated by let or case preserve nested MFunction structure with each stage closure matching its outermost arg count"

This implementation enforces it via:

1. **Fully peelable path**: `paramCount == totalArity` ensures all params are consumed, type is flattened
2. **Curried path**: `paramCount == List.length args` (exact match, not truncation) ensures params match first stage
3. **Explicit assertion**: After building monoParams, verify `length monoParams == length (Types.stageParamTypes effectiveMonoType)`

---

## Verification

### Unit Tests
```bash
cd compiler && npx elm-test-rs --fuzz 1
```

The following tests should pass:
- `WrapperCurriedCallsTest.elm` - Tests MONO_016 stage arity invariant
- `MonoFunctionArity.elm` - Tests closure param count matches stage arity

### Integration Tests
```bash
cmake --build build --target check
```

---

## File Change Summary

| File | Change |
|------|--------|
| `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Replace `specializeLambda` body (lines 233-365), delete `peelNParams` and related helpers (lines 105-191) |

**No changes to:**
| File | Reason |
|------|--------|
| `TypeSubst.elm` | TLambda already non-flattening |
| `Types.elm` | `stageArity`/`stageParamTypes` already exist |
| `Closure.elm` | `flattenFunctionType` and `ensureCallableTopLevel` already correct |
| `Expr.elm` | Already uses `stageArity` for `remaining_arity` |
| `invariants.csv` | MONO_016 already correctly worded |

---

## Resolved Questions

### Q1: `totalArity == 0` (non-function types)
**Resolution:** Keep as defensive path with comment noting it should be unreachable in well-typed Elm. Build `MFunction` from `allParams` and `TOpt.typeOf finalBodyExpr` as fallback.

### Q2: `paramCount == 0`
**Resolution:** Crash immediately. This indicates `specializeLambda` was called on a non-lambda expression, which is a bug at the caller. Valid Elm `TOpt.Function` nodes always have at least one param.

### Q3: `paramCount != stageArity` in curried path
**Resolution:** Crash, don't truncate. With staged `applySubst`, `monoType0.args` has length 1 for each stage, so `paramCount` must exactly match. If not, this is a type/syntax mismatch indicating a compiler bug. This is stricter than the original design doc's "truncate" suggestion, but is the correct behavior.

### Q4: `peelFunctionChain` behavior
**Confirmed:** Already correct. It walks through `Function`/`TrackedFunction` nodes and stops at the first non-lambda (like `Let`), returning accumulated params. For `\x -> let ... in \y -> body`, returns `([x], Let(...))`.

### Q5: `peelNParams` deletion
**Confirmed:** Safe to delete. Only caller is the old `specializeLambda` body being replaced. No other references in codebase.

---

## Summary

This plan is:
- Aligned with the staged-Mono design in `mono-still-curried.md`
- Correctly distinguishes fully-peelable vs wrapper lambdas
- Enforces MONO_016 both structurally and via explicit assertion
- Removes the need for the old `outerStageArity`/`peelNParams` logic
- Prevents under-parameterized closures that caused missing captures downstream
