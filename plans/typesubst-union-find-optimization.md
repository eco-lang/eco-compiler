# TypeSubst Union-Find & Changed-Flag Optimization

## Goal

Improve monomorphization substitution performance in `TypeSubst.elm` by:
1. Eliminating long MVar→MVar alias chains via union-find path compression
2. Reducing GC pressure in `resolveMonoVars` via a changed-flag pattern
3. Normalizing all substitution insertions through a central `insertBinding` helper

No public API changes — all modifications are internal to `TypeSubst.elm`.

## File

`compiler/src/Compiler/Monomorphize/TypeSubst.elm` — the only file modified.

(`State.elm`'s `type alias Substitution = Dict Name Mono.MonoType` is unchanged.)

---

## Step 1: Add helper functions (new code, insert after imports ~line 37)

### 1a. `listMapChanged` and `dictMapChanged`

```elm
listMapChanged :
    (a -> ( Bool, a ))
    -> List a
    -> ( Bool, List a )
```

Folds over a list, threading a `changed` boolean. Only rebuilds the list when at least one element changes.

```elm
dictMapChanged :
    (v -> ( Bool, v ))
    -> Dict Name v
    -> ( Bool, Dict Name v )
```

Same pattern for `Dict Name v`. Uses `Dict.foldl` with a `(Bool, Dict)` accumulator.

### 1b. `findRootVar`

```elm
findRootVar : Name -> Substitution -> ( Name, Substitution )
```

Union-find path compression over the substitution. Given a name:
- If `Dict.get name subst` yields `Just (Mono.MVar parentName _)` and `parentName /= name`:
  recursively find root, then rewrite `name`'s entry to point directly to root.
- Otherwise: `name` is the root — return `(name, subst)`.

Uses existing `constraintFromName` to reconstruct constraints for compressed entries.

### 1c. `normalizeMonoType`

```elm
normalizeMonoType : Substitution -> Mono.MonoType -> ( Mono.MonoType, Substitution )
```

For `MVar varName _`: calls `findRootVar`, returns canonicalized MVar if root differs.
For non-MVar types: returns `(ty, subst)` unchanged.

### 1d. `insertBinding`

```elm
insertBinding : Name -> Mono.MonoType -> Substitution -> Substitution
```

Normalizes `ty` via `normalizeMonoType`, then `Dict.insert name normalizedTy subst1`.
This is the **single entry point** for all substitution mutations.

---

## Step 2: Rewrite `unifyHelp` TVar branch (lines 106–127)

**Current** (line 123–127):
```elm
Just existingMono ->
    unifyMonoMono existingMono monoType
        (Dict.insert name monoType subst)

Nothing ->
    Dict.insert name monoType subst
```

**New:**
```elm
Just existingMono ->
    let
        substWithTransitives =
            unifyMonoMono existingMono monoType subst
    in
    insertBinding name monoType substWithTransitives

Nothing ->
    insertBinding name monoType subst
```

Key change: `unifyMonoMono` now receives the *original* subst (not one with the new binding pre-inserted), then `insertBinding` adds the normalized binding afterwards. This "unify first, then set name" ordering is semantically equivalent to the current "insert then unify" ordering because `unifyMonoMono` never reads the mapping for `name` — it only adds bindings for MVar names it encounters in `existingMono`/`monoType` via `Dict.insert`. The two orderings differ only in the order of commutative `Dict.insert` calls to distinct keys. Not pre-inserting has the advantage of avoiding transient self-references during reconciliation.

---

## Step 3: Rewrite `unifyHelp` record-extension branch (line 204)

**Current:**
```elm
Dict.insert extName (Mono.MRecord remainingFields) substWithFields
```

**New:**
```elm
insertBinding extName (Mono.MRecord remainingFields) substWithFields
```

This is the only other bare `Dict.insert` in `unifyHelp`.

---

## Step 4: Rewrite `unifyMonoMono` MVar cases (lines 250–262)

Replace the three `Dict.insert` calls with `insertBinding`:

```elm
( Mono.MVar name1 _, Mono.MVar name2 _ ) ->
    if name1 == name2 then
        subst
    else
        insertBinding name1 m2 subst

( Mono.MVar name _, _ ) ->
    insertBinding name m2 subst

( _, Mono.MVar name _ ) ->
    insertBinding name m1 subst
```

The rest of `unifyMonoMono` (MFunction, MList, MCustom, wildcard) stays the same.

---

## Step 5: Rewrite `resolveMonoVars` / `resolveMonoVarsHelp` (lines 330–370)

### 5a. `resolveMonoVars` — same signature, routes through changed-flag helper

```elm
resolveMonoVars : Substitution -> Mono.MonoType -> Mono.MonoType
resolveMonoVars subst monoType =
    monoType
        |> resolveMonoVarsHelp Set.empty subst
        |> Tuple.second
```

### 5b. `resolveMonoVarsHelp` — returns `( Bool, Mono.MonoType )`

New signature (internal):
```elm
resolveMonoVarsHelp : Set Name -> Substitution -> Mono.MonoType -> ( Bool, Mono.MonoType )
```

For each constructor:
- **MVar**: cycle-check via `visiting` set. If not visiting and `Dict.get name subst` succeeds, recurse on the resolved value and **always return `True`** — the MVar node itself was replaced, regardless of whether the resolved subtree changed internally. This is correct because from the caller's perspective the node changed from `MVar name _` to the resolved type.
- **MFunction/MList/MTuple/MRecord/MCustom**: use `listMapChanged` / `dictMapChanged` with recursive call. Only rebuild the node if `changed == True`; otherwise return `(False, monoType)` — the original reference.
- **Leaf types** (MInt, MFloat, etc.): `(False, monoType)`.

MVar branch shape:
```elm
Mono.MVar name _ ->
    if Set.member name visiting then
        ( False, monoType )
    else
        case Dict.get name subst of
            Just resolved ->
                let
                    ( _, newResolved ) =
                        resolveMonoVarsHelp (Set.insert name visiting) subst resolved
                in
                -- We definitely changed the node from MVar -> newResolved.
                ( True, newResolved )

            Nothing ->
                ( False, monoType )
```

This avoids allocating new constructor nodes when nothing changes inside a subtree.

---

## Step 6 (optional): Use `findRootVar` inside `resolveMonoVarsHelp` MVar case

In the MVar branch of `resolveMonoVarsHelp`, before looking up `Dict.get name subst`, first call `findRootVar name subst` to get `(rootName, subst1)`, then look up `rootName` in `subst1`. This further flattens alias chains during resolution.

Since `resolveMonoVarsHelp` currently doesn't thread the substitution (it's read-only), integrating `findRootVar` would require either:
- Ignoring the updated subst (losing the compression benefit), or
- Threading subst through all recursive calls (larger refactor).

**Decision:** Skip this for now. The `insertBinding`/`normalizeMonoType` changes at unification time already collapse chains at creation. Resolution reads a already-compressed substitution. We can revisit if profiling shows long chains persisting.

---

## Verification

### Build
```bash
cd compiler && npx elm-test-rs --project build-xhr --fuzz 1
```

### E2E
```bash
cmake --build build --target check
```

### What to look for
- All existing tests pass (no behavioral changes).
- No new compiler warnings in `TypeSubst.elm`.
- Monomorphization of complex generic code (e.g., Dict, Array, Json.Decode) produces identical output.

---

## Resolved design decisions

1. **`unifyHelp` TVar — subst ordering**: Adopted "unify first, then set name" (call `unifyMonoMono existingMono monoType subst` on the original subst, then `insertBinding name monoType` on the result). This is semantically equivalent to the current "insert then unify" ordering because `unifyMonoMono` never reads the mapping for `name` — it only adds bindings for MVar names it encounters in `existingMono`/`monoType`. The two orderings differ only in commutative `Dict.insert` calls to distinct keys. Not pre-inserting avoids transient self-references during reconciliation.

2. **`resolveMonoVarsHelp` MVar changed-flag**: When `Dict.get name subst` succeeds, **always return `changed = True`**. The MVar node itself is replaced by the resolved type, so from the caller's perspective the node changed — regardless of whether the resolved subtree had further internal changes. The `changed` flag from the recursive call on the resolved value is discarded (`( _, newResolved )`).
