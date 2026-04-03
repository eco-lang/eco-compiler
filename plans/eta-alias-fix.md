# Plan: MVarId Alias Map for TailDef Specialization

## Problem

When monomorphizing cycle TailDefs (e.g. `List.foldrHelper`), the canonical type from `getDefCanonicalType` uses one set of MVarIds (e.g. 943, 944), but the arg types use different MVarIds (941, 942) and the body's `meta.tipe` uses yet another set (947, 945). The `sharedSubst` only binds scheme MVarIds (943→MInt, 944→MList MInt), so when we apply it to arg or body types, the unrelated MVarIds fall through as `MVar CEcoValue`, producing broken specializations.

## Solution

Explicitly link all MVarId families (scheme, args, body) back to the canonical scheme via structural type matching, then extend the substitution with those aliases before applying it.

---

## Step-by-Step Implementation

### Step 1: Add `MVarAliasMap` type alias to TypeSubst.elm

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm`

Add a type alias:
```elm
type alias MVarAliasMap = Dict Int Int
```

Keys are `Id.toComparable localMVarId`, values are `Id.toComparable schemeMVarId`. Export it from the module.

### Step 2: Add `linkSchemeToLocalType` to TypeSubst.elm

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm`

Structurally walk two `Can.Type MVarId` trees in lockstep. When both sides are `TVar`, record `Id.toComparable localId → Id.toComparable schemeId` in the alias map. Recurse into all constructors:

- `TLambda`: recurse on arg and result
- `TType`: recurse on type args (zip the two lists)
- `TRecord`: recurse on matching field types by name; handle extension var (both `Just` → alias; otherwise skip)
- `TTuple`: recurse on elements
- `TAlias`: recurse on the `Filled`/`Holey` inner type and alias args
- `TUnit`: no-op
- Mismatched shapes: no-op (precondition violation, but safe to skip)

**Signature:**
```elm
linkSchemeToLocalType : Can.Type MVarId -> Can.Type MVarId -> MVarAliasMap -> MVarAliasMap
```

No MVarEnv threading needed — this is a pure structural match, no fresh vars or constraints.

### Step 3: Add `extendSubstWithAliases` to TypeSubst.elm

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm`

Given an `MVarAliasMap` and a `Substitution`, produce a new `Substitution`. **Skip-if-exists policy:** only add `localId → monoType` if `localId` is not already bound. This ensures `unify`/`unifyExtend` bindings always win over alias-derived ones.

```elm
extendSubstWithAliases : MVarAliasMap -> Substitution -> Substitution
extendSubstWithAliases aliasMap subst =
    Dict.foldl
        (\localId schemeId acc ->
            if Dict.member localId acc then
                acc
            else
                case Dict.get schemeId subst of
                    Just monoT -> Dict.insert localId monoT acc
                    Nothing -> acc
        )
        subst
        aliasMap
```

### Step 4: Add `computeDefAliasMap` to Specialize.elm

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

For a TailDef, compute the alias map by linking:
1. `getDefCanonicalType def` (the scheme = full function type) against `returnType` (also the full function type). This captures all MVarId correspondences for args AND result in one structural walk.
2. Each individual arg's `Can.Type` against the corresponding flattened scheme arg type. This is cheap insurance for edge cases where arg types introduce extra variables not in the overall function type.
3. The scheme's result type against `TOpt.typeOf body`. This captures body MVarIds.

**Note on arg linking:** Under normal circumstances, arg types and the def-level type share the same MVarId family (both rewritten through the same `bindingCtx` in `AssignMVarIds`). So scheme↔returnType linking usually covers arg MVarIds too. Per-arg linking is low-cost insurance.

```elm
computeDefAliasMap : TOpt.Def MVarId -> TypeSubst.MVarAliasMap
computeDefAliasMap def =
    case def of
        TOpt.TailDef _ _ args body returnType _ ->
            let
                schemeType = getDefCanonicalType def
                -- flattenTLambda or manual chain walk to get (schemeArgTypes, schemeResultType)
                (schemeArgTypes, schemeResultType) = flattenSchemeType schemeType
                bodyType = TOpt.typeOf body
            in
            Dict.empty
                -- Link full function type: scheme ↔ returnType
                |> TypeSubst.linkSchemeToLocalType schemeType returnType
                -- Link individual args (cheap insurance)
                |> (\acc -> List.foldl (\(sArg, (_, lArg)) a -> TypeSubst.linkSchemeToLocalType sArg lArg a) acc (List.map2 Tuple.pair schemeArgTypes (List.map Tuple.second (List.map (\(loc, ct) -> (loc, ct)) args))))
                -- Link body type
                |> TypeSubst.linkSchemeToLocalType schemeResultType bodyType
        _ ->
            Dict.empty
```

The per-arg linking zip is a bit awkward in pseudocode; the actual implementation will use `List.map2 Tuple.pair` on `schemeArgTypes` and the arg `Can.Type` list extracted from `args`.

For the scheme flattening, either:
- Use `TypeSubst.flattenTLambda` if exported, or
- Write a local helper that walks the TLambda chain (trivial 5-line function, same as `buildFuncType` in reverse)

### Step 5: Wire alias map into `specializeFuncDefInCycle`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

In `specializeFuncDefInCycle` (line 950), TailDef branch (line 963):
1. Compute `aliasMap = computeDefAliasMap def`
2. After computing `augmentedSubst` (line 980-986), extend it:
   ```elm
   augmentedSubstFull = TypeSubst.extendSubstWithAliases aliasMap augmentedSubst
   ```
3. Use `augmentedSubstFull` for:
   - `specializeExpr body augmentedSubstFull stateWithParams` (line 988-989)
   - **Replace `applySubstFV` with plain `TypeSubst.applySubst`** for returnType (line 1005-1006):
     ```elm
     monoFuncType =
         Mono.forceCNumberToInt (Tuple.first (TypeSubst.applySubst state.ctx.mvarEnv augmentedSubstFull returnType))
     ```

**Rationale for switching to `applySubst`:** `applySubstFV` deliberately drops bindings for MVarIds not in the annotation's FreeVars. Alias-injected keys for body/returnType vars won't be in FreeVars, so they'd be filtered out. Since we're applying the substitution to the def's own canonical type (not an arbitrary cross-scheme expression), FreeVars filtering is not needed here and would actively break the fix.

**Keep `applySubstFV` unchanged** for expression types inside `specializeExpr` — that's where cross-scheme isolation matters.

No signature change needed for `specializeFuncDefInCycle`.

### Step 6: Wire alias map into `specializeDef` (local TailDefs)

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

In `specializeDef` (line 2821), TailDef branch (line 2831):
1. Compute `aliasMap = computeDefAliasMap def`
2. After computing `augmentedSubst` (line 2850-2856), extend it:
   ```elm
   augmentedSubstFull = TypeSubst.extendSubstWithAliases aliasMap augmentedSubst
   ```
3. Use `augmentedSubstFull` for `specializeExpr expr augmentedSubstFull stateWithParams`

**Note:** `specializeDef` for TailDef does not currently apply the subst to returnType (it doesn't produce `monoFuncType`), so there's no `applySubstFV` call to change here. The alias extension only affects body expression specialization.

### Step 7: Export new functions from TypeSubst module

**File:** `compiler/src/Compiler/Monomorphize/TypeSubst.elm` (line 1-5)

Add to the exposing list:
- `MVarAliasMap`
- `linkSchemeToLocalType`
- `extendSubstWithAliases`

`flattenTLambda` export is optional — a local helper in Specialize.elm that walks the TLambda chain is trivial and avoids coupling.

### Step 8: Test

1. Run frontend tests: `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1`
2. Run E2E tests: `cmake --build build --target full`
3. Specifically check that `EqualityIntPapWithStringChain` passes (the motivating test)
4. Check MONO_021/MONO_024 invariants pass — no residual `MVar CEcoValue` in fully monomorphic TailFunc specializations

---

## Resolved Questions

### Q1: `flattenTLambda` export
**Resolution:** Not required. Linking scheme↔returnType covers args transitively. For the body type linkage, we need the scheme's result type — implement a trivial local helper in Specialize.elm that walks the TLambda chain, or reuse `flattenTLambda` if already convenient. No coupling concern either way.

### Q2: Per-arg linking redundancy
**Resolution:** Keep per-arg linking as cheap insurance. Under normal circumstances, arg types and the def-level type share the same MVarId family (both from the same `bindingCtx` in `AssignMVarIds`), so scheme↔returnType linking covers them. But per-arg linking handles edge cases where args introduce extra type variables and costs nothing.

### Q3: `applySubstFV` filtering (was CRITICAL)
**Resolution:** Switch the specific TailDef `returnType` substitution call (line 1006 in `specializeFuncDefInCycle`) from `applySubstFV` to plain `TypeSubst.applySubst`. Rationale:
- `applySubstFV` deliberately drops bindings for MVarIds not in the annotation's FreeVars
- Alias-injected keys for body/returnType vars would be filtered out
- For the def's own canonical type, FreeVars filtering provides no safety benefit
- Keep `applySubstFV` unchanged for expression-level types in `specializeExpr` where cross-scheme isolation matters

### Q4: Are args already handled by `unifyExtend`?
**Resolution:** Yes. The `unifyExtend` loop at line 980-986 directly unifies each arg's `Can.Type` with its `MonoType`, populating the substitution for arg MVarIds. The real gap is body/returnType MVarIds only. The alias fix primarily addresses those.

### Q5: Non-TailDef `Def` in cycles
**Resolution:** Not needed. The `Def` constructor stores its canonical type directly (not reconstructed), so it uses the same MVarIds as the scheme. No aliasing required.

### Q6: Overwrite safety in `extendSubstWithAliases`
**Resolution:** Skip-if-exists policy. Aliases are secondary sources of truth; `unify`/`unifyExtend` bindings always win. Implementation uses `Dict.member` check before insertion.

### Q7: Record extension variables
**Resolution:** Handle in `linkSchemeToLocalType`: if both sides have `Just extId`, record the alias. If one is `Nothing` and the other `Just`, skip (shape mismatch — safe no-op).
