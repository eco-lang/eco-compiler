# Closure Constraint Propagation into Lambdas

## Problem

Two related failures where monomorphization leaves `MVar _ CEcoValue` in closure parameter/result positions, violating MONO_021:

1. **Record update lambdas**: `{ r | fn = \x -> x }` — the replacement lambda `\x -> x` (type `a -> a`) isn't constrained by the record field's canonical type (`a -> Int`), so its internal type variables remain as `MVar _ CEcoValue`.

2. **Higher-order composition**: `compose identity identity 1` — the inner lambda `\x -> f (g x)` has internal type variables (the "connection type" between `f` and `g`) that aren't resolved because `specializeLambda` doesn't feed back the already-concrete `monoType0` into the substitution.

Both stem from the same root cause: **missing constraint propagation from known monomorphic types into lambda substitutions**.

## Fix 1: `specializeLambda` — Feed `monoType0` back via `unifyExtend`

**File**: `compiler/src/Compiler/Monomorphize/Specialize.elm`
**Function**: `specializeLambda` (lines 177–255)

### Current behavior

`specializeLambda` computes `monoType0` from `canType + subst`, then uses the original `subst` for parameters and body. Any extra constraints implied by `monoType0` (e.g., that certain type variables must be `MInt`) are lost.

### Change

After computing `monoType0`, refine the substitution:

```elm
-- After line ~188 (monoType0 definition):
refinedSubst : Substitution
refinedSubst =
    TypeSubst.unifyExtend canType monoType0 subst
```

Then use `refinedSubst` instead of `subst` in three places:
1. Computing `monoParams` (line ~210): `TypeSubst.applySubst refinedSubst paramCanType`
2. Specializing the body (line ~234): `specializeExpr bodyExpr refinedSubst stateWithLambda`

### Why this is safe

- `monoType0` is derived from `canType + subst`, so `unifyExtend canType monoType0 subst` only adds bindings that are already implied — it makes implicit constraints explicit.
- This is the same `unifyExtend` mechanism already used for call-site type propagation elsewhere in the specializer.
- The curried type structure is preserved (we don't flatten), so GlobalOpt's GOPT_001 canonicalization is unaffected.

### Why this fixes composition

For `\x -> f (g x)` inside `compose identity identity 1`:
- `monoType0` = `MFunction [MInt] MInt` (concrete from enclosing specialization)
- `unifyExtend canType monoType0 subst` binds the "connection type" variable to `MInt`
- `refinedSubst` propagates to params (`x : MInt`) and body (captured `f`, `g` get concrete types)
- No `CEcoValue` MVars remain

## Fix 2: `specializeExpr` Update branch — Propagate field types into update lambdas

**File**: `compiler/src/Compiler/Monomorphize/Specialize.elm`
**Function**: `specializeExpr`, `TOpt.Update` branch (lines 1234–1245)
**Also**: `specializeUpdates` (lines 2160–2173)

### Current behavior

`specializeUpdates` passes through the ambient `subst` to each update expression. For a lambda like `\x -> x` assigned to field `fn : a -> Int`, no constraints from the field type reach the lambda.

### Change

Replace the current `specializeUpdates` call with inline logic that, for each updated field:

1. Gets the canonical record type from `TOpt.typeOf record` (which is a `Can.TRecord fields _`)
2. For each field being updated, looks up the field's canonical type from that record type
3. Computes the field's monomorphic type: `Mono.forceCNumberToInt (TypeSubst.applySubst subst fieldCanType)`
4. Gets the update expression's canonical type: `TOpt.typeOf updateExpr`
5. Refines the substitution: `TypeSubst.unifyExtend updateCanType fieldMonoType subst`
6. Specializes the update expression under this refined substitution

```elm
TOpt.Update _ record updates canType ->
    let
        monoType =
            Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)

        ( monoRecord, state1 ) =
            specializeExpr record subst state

        -- Get canonical record type for field type lookup
        recordCanType =
            TOpt.typeOf record

        getFieldCanType fieldName =
            case recordCanType of
                Can.TRecord fields _ ->
                    case Dict.get identity fieldName fields of
                        Just (Can.FieldType _ fieldT) ->
                            Just fieldT

                        Nothing ->
                            Nothing

                _ ->
                    Nothing

        ( monoUpdates, state2 ) =
            Dict.foldl A.compareLocated
                (\locName expr ( acc, st ) ->
                    let
                        fieldName =
                            A.toValue locName

                        refinedSubst =
                            case getFieldCanType fieldName of
                                Just fieldCanType ->
                                    let
                                        fieldMonoType =
                                            Mono.forceCNumberToInt
                                                (TypeSubst.applySubst subst fieldCanType)
                                    in
                                    TypeSubst.unifyExtend (TOpt.typeOf expr) fieldMonoType subst

                                Nothing ->
                                    subst

                        ( monoExpr, newSt ) =
                            specializeExpr expr refinedSubst st
                    in
                    ( ( fieldName, monoExpr ) :: acc, newSt )
                )
                ( [], state1 )
                updates
    in
    ( Mono.MonoRecordUpdate monoRecord monoUpdates monoType, state2 )
```

### Why this is safe

- Uses canonical field types (source of truth) and the existing substitution — never `Mono.typeOf` on already-monomorphized values.
- `unifyExtend` only adds bindings implied by the field type constraint, so well-typed programs stay well-typed.
- Falls back to original `subst` if field lookup fails (defensive).

### Why this fixes the record update case

For `{ r | fn = \x -> x }` where `fn : a -> Int`:
- `fieldCanType` = `a0 -> Int`
- `fieldMonoType` = `MFunction [MVar "a0" CEcoValue] MInt`
- `updateCanType` = `a1 -> a1`
- `unifyExtend` maps `a1 -> MInt`
- Lambda specialization with `refinedSubst` yields `MFunction [MInt] MInt`

## Interaction between the two fixes

Fix 1 (specializeLambda) subsumes some cases of Fix 2 but not all:
- **Fix 1** handles the case where the lambda's **own function type** is already fully determined by the ambient context. This is the composition case.
- **Fix 2** handles the case where the constraint comes from a **record field type** that isn't in the ambient `subst`. This is the record update case.

Both fixes are needed because they address different propagation paths. They compose safely: if both apply to the same lambda, `unifyExtend` is idempotent for consistent constraints.

## Testing

After implementation, verify with:
```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
cmake --build build --target check
```

Both test failures described in the problem statement should be resolved, and no existing tests should regress.

## Invariants affected

- **MONO_020**: Strengthened — more complete constraint propagation for local lambdas
- **MONO_021**: Directly addressed — eliminates `CEcoValue` MVars in closure params/results for these patterns
- **GOPT_001**: Unaffected — curried type structure preserved, GlobalOpt still canonicalizes
