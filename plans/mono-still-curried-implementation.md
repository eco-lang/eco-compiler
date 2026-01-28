# Mono-Still-Curried Implementation Plan

## Overview

This plan implements `design_docs/mono-still-curried.md`: allow curried (staged) functions through monomorphization when they cannot be simply uncurried (e.g., lambdas separated by `let`/`case`). Simple directly-nested lambda chains continue to be flattened into a single uncurried stage.

### Key Semantic Change

`MFunction` becomes **stage-aware**: `MFunction argTypes resultType` means "expects `argTypes` now, returns `resultType`" — where `resultType` may itself be another `MFunction` (curried/staged).

---

## Step-by-Step Implementation

### Step 1: Remove TLambda flattening in `TypeSubst.applySubst`

**File:** `compiler/src/Compiler/Generate/Monomorphize/TypeSubst.elm`

**Current code (lines ~250-261):**
```elm
Can.TLambda from to ->
    let
        argMono = applySubst subst from
        resultMono = applySubst subst to
    in
    case resultMono of
        Mono.MFunction restArgs ret ->
            Mono.MFunction (argMono :: restArgs) ret
        _ ->
            Mono.MFunction [ argMono ] resultMono
```

**Change to:**
```elm
Can.TLambda from to ->
    let
        argMono = applySubst subst from
        resultMono = applySubst subst to
    in
    Mono.MFunction [ argMono ] resultMono
```

Remove the `case resultMono of` branch that flattens. Each `TLambda` maps to exactly one `MFunction` level.

**Effect:** `a -> b -> c` now becomes `MFunction [a] (MFunction [b] c)` instead of `MFunction [a, b] c`.

**Note:** `extractParamTypes` (line 209-218) is unchanged — it still recursively flattens nested `MFunction` and is used when an explicit flattened view is needed.

---

### Step 2: Add `stageParamTypes` and `stageArity` to `Types.elm`

**File:** `compiler/src/Compiler/Generate/MLIR/Types.elm`

**Add after `countTotalArity` (after line ~274):**
```elm
{-| Stage parameter types: outermost MFunction argument list. -}
stageParamTypes : Mono.MonoType -> List Mono.MonoType
stageParamTypes monoType =
    case monoType of
        Mono.MFunction argTypes _ ->
            argTypes

        _ ->
            []


{-| Stage arity: number of arguments expected in the current stage. -}
stageArity : Mono.MonoType -> Int
stageArity monoType =
    List.length (stageParamTypes monoType)
```

**Update module exports (line 5):**
```elm
, isFunctionType, functionArity, countTotalArity, decomposeFunctionType
, stageParamTypes, stageArity, isEcoValueType
```

---

### Step 3: Replace `specializeLambda` with stage-aware logic

**File:** `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm`

**Replace the body of `specializeLambda` (lines 118-223) with the design's §3.1 logic.**

The new logic:
1. Compute `monoType0 = TypeSubst.applySubst subst canType` (now stage-preserving, no flattening).
2. Compute `(flatArgTypes, flatRetType) = Closure.flattenFunctionType monoType0` and `totalArity = List.length flatArgTypes`.
3. Peel lambda chain: `(allParams, finalBodyExpr) = peelFunctionChain lambdaExpr`. Let `paramCount = List.length allParams`.
4. Determine mode:
   - `isFullyPeelable = paramCount == totalArity && totalArity > 0`
5. Compute `effectiveMonoType`:
   - If fully peelable: `Mono.MFunction flatArgTypes flatRetType` (single uncurried stage).
   - Otherwise: `monoType0` (keep nested structure).
6. Compute `effectiveParamTypes`:
   - If fully peelable: `flatArgTypes`.
   - Otherwise: outer stage args from `monoType0`, crash if `paramCount > List.length outerArgs`.
7. `deriveParamType` uses `effectiveParamTypes` instead of `funcTypeParams`.
8. Build closure with `effectiveMonoType` instead of `monoType`.

**This also removes the strict MONO_016 assertion** (`List.length allParams /= List.length funcTypeParams` crash). It is replaced by the curried-mode crash that only fires when `paramCount > outerStageArgs`.

**Import needed:** Add `Closure` to the import if `flattenFunctionType` isn't already accessible. Currently `Closure` is already imported.

---

### Step 4: Change `countTotalArity` to `stageArity` in `Expr.elm`

**File:** `compiler/src/Compiler/Generate/MLIR/Expr.elm`

**Three locations** where `remaining_arity` is set for `eco.papExtend`:

| Line  | Current                              | Change to                        |
|-------|--------------------------------------|----------------------------------|
| 1037  | `Types.countTotalArity funcType`     | `Types.stageArity funcType`      |
| 1697  | `Types.countTotalArity funcType`     | `Types.stageArity funcType`      |
| 1798  | `Types.countTotalArity funcType`     | `Types.stageArity funcType`      |

**Do NOT change** the `papCreate` arity computation in `generateClosure`. It uses `numCaptured + List.length closureInfo.params` which is correct: after the `specializeLambda` change, `closureInfo.params` reflects stage arity, so `arity - num_captured = stageArity`.

---

### Step 5: Update MONO_016 invariant definition

**File:** `design_docs/invariants.csv` (line 131)

**Current:**
> For every MonoClosure with type MFunction the number of params (List.length closureInfo.params) must equal Types.countTotalArity of its monoType...

**Change to:**
> For every MonoClosure with type MFunction the number of params (List.length closureInfo.params) must equal the length of the outermost MFunction argument list of its monoType (i.e. stage arity). Simple directly-nested lambda chains are uncurried into a single flat MFunction stage while lambdas separated by let or case preserve nested MFunction structure with each stage closure matching its outermost arg count

**Update source reference to:**
> Compiler.Generate.Monomorphize.Specialize|Compiler.Generate.Monomorphize.Closure

---

### Step 6: Verify PapExtendArity.elm test logic (no changes expected)

**File:** `compiler/tests/Compiler/Generate/CodeGen/PapExtendArity.elm`

The current logic already:
- Tracks `remaining = arity - num_captured` for `papCreate` ✅
- Tracks `resultRemaining = remaining_arity - numNewArgs` for `papExtend` ✅
- Verifies `remaining_arity` attribute matches source PAP's remaining ✅

With `stageArity` in codegen, `remaining_arity` will now correctly reflect per-stage remaining, and the tracking map will match. **No code changes needed.**

---

### Step 7: Verify Closure.elm (no changes expected)

**File:** `compiler/src/Compiler/Generate/Monomorphize/Closure.elm`

Per the design (§7): "No semantic changes; `flattenFunctionType` still flattens for `ensureCallableTopLevel` and alias closures, which is correct even with nested `MFunction`s."

`ensureCallableTopLevel` already handles under-parameterized closures (line 53: `if List.length closureInfo.params >= List.length argTypes`) by wrapping them. With curried closures, `flattenFunctionType` will give the full arg list and the closure will have fewer params, triggering the wrapper path — which is correct behavior.

The kernel `kernelAbiType` fix from the previous implementation remains correct.

**No code changes needed.**

---

### Step 8: Run tests and verify

```bash
cd compiler && npx elm-test --fuzz 1
```

---

## File Change Summary

| File | Change |
|------|--------|
| `compiler/src/Compiler/Generate/Monomorphize/TypeSubst.elm` | Remove TLambda flattening in `applySubst` (delete 4 lines, simplify to 1) |
| `compiler/src/Compiler/Generate/MLIR/Types.elm` | Add `stageParamTypes` + `stageArity`, update exports |
| `compiler/src/Compiler/Generate/Monomorphize/Specialize.elm` | Replace `specializeLambda` body with stage-aware dual-mode logic |
| `compiler/src/Compiler/Generate/MLIR/Expr.elm` | Change 3× `countTotalArity` → `stageArity` |
| `design_docs/invariants.csv` | Update MONO_016 to stage arity semantics |

**No changes needed:**
| File | Reason |
|------|--------|
| `Closure.elm` | `flattenFunctionType` + wrapper logic already handles nested `MFunction` |
| `PapExtendArity.elm` | Already tracks remaining arity correctly |

---

## Resolved Design Points

- **`peelFunctionChain`**: Kept as-is. The design explicitly says to keep it (§3, §7).
- **`extractParamTypes`**: Kept as-is. It's the "explicit flattening" helper used when a total view is needed.
- **`flattenFunctionType`**: Kept as-is. Used by `ensureCallableTopLevel` and `specializeLambda` (fully-peelable mode).
- **`functionArity`**: Not used by our code paths. No change needed.
