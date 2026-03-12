# Value-Level Lazy Multi-Specialization

## Problem

Polymorphic let-bound values whose types *contain* lambdas (e.g. `{ fn = \x -> x }`) get eagerly specialized under incomplete substitutions. At specialization time, CEco type variables like `a` in `a -> a` remain unconstrained, producing `MVar a CEcoValue` closures that are later erased to `MErased`. Call sites *do* learn the concrete type (e.g. `a = Int` via `unifyCallSiteWithRenaming`), but by then the closure is already built with the wrong type. This violates MONO_021/MONO_024.

## Design Summary

Introduce demand-driven multi-specialization for *values* whose type contains lambdas and unconstrained CEco type variables, analogous to the existing `localMulti` for let-bound functions:

1. At `let r = expr in body`, if `r`'s type contains lambdas and CEco TVars, **defer** specialization of `expr`.
2. Push a `valueMulti` stack entry. Specialize `body` normally.
3. When `VarLocal r` is encountered during body specialization, the current substitution determines the *requested* monomorphic type. Record an instance.
4. After body specialization, specialize `expr` once per distinct requested type under a fully-informed substitution.
5. Wrap `body` in nested `MonoLet`s for each instance.

---

## Decisions (locked in)

These were open questions during design; all are now resolved:

- **Name prefix (Q2):** Value-multi instances use `$v0`, `$v1`, ... suffix. Function-multi instances continue using `$0`, `$1`, ... No ambiguity since `TLambda` defs always go to `localMulti` and non-`TLambda` defs go to `valueMulti`.
- **Branch order in `Let` (Q6):** The `TOpt.Let` dispatch is:
  1. `Can.TLambda _ _` → `localMulti` path (existing),
  2. else if `shouldUseValueMulti` → `valueMulti` path (new),
  3. else → existing non-function path (unchanged).
- **Instance key type (Q8):** `Dict (List String) ValueInstanceInfo` keyed by `Mono.toComparableMonoType`, matching `LocalMultiState`.
- **Purity guard (Q1):** Skipped initially. Elm `let` values are pure; `localMulti` already duplicates definitions without a purity guard. Add later only if Debug/port edge cases surface.
- **Destruct bindings (Q3):** Not included. Destructors get concrete types from pattern matching context.
- **Value-only cycles (Q4):** No overlap. Cycles are handled at the node level before `TOpt.Let` is reached.
- **Double body specialization on empty instances (Q5):** Accepted. Matches existing `localMulti` fallback pattern; the case is rare (unused polymorphic value with lambdas).

---

## Implementation Steps

### Step 1: Add `ValueMultiState` types to `State.elm`

**File:** `compiler/src/Compiler/Monomorphize/State.elm`

Add new type aliases alongside the existing `LocalInstanceInfo`/`LocalMultiState`:

```elm
type alias ValueInstanceInfo =
    { freshName : Name
    , monoType : Mono.MonoType
    , subst : Substitution
    }

type alias ValueMultiState =
    { defName : Name
    , defCanType : Can.Type
    , def : TOpt.Def
    , instances : Dict (List String) ValueInstanceInfo
    }
```

Key: `Dict (List String)` uses `Mono.toComparableMonoType` as key, identical to `LocalMultiState.instances`.

Add `valueMulti : List ValueMultiState` to `SpecContext`:

```elm
type alias SpecContext =
    { ...
    , localMulti : List LocalMultiState
    , valueMulti : List ValueMultiState
    , ...
    }
```

Initialize `valueMulti = []` in `initState`.

Update the module's `exposing` list to export `ValueInstanceInfo`, `ValueMultiState`.

### Step 2: Add type predicates to `Specialize.elm`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

Add two helpers:

```elm
typeContainsLambda : Can.Type -> Bool
```
Recursively checks if a `Can.Type` contains any `Can.TLambda`. Walks `TType` args, `TRecord` fields, `TTuple` elements, `TAlias` inner types.

```elm
hasCEcoTVar : Can.Type -> Bool
```
Checks `collectCanTypeVars canType []` for any name where `constraintFromName name == Mono.CEcoValue`.

### Step 3: Add `shouldUseValueMulti` predicate

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

```elm
shouldUseValueMulti : Can.Type -> Bool
shouldUseValueMulti defCanType =
    typeContainsLambda defCanType && hasCEcoTVar defCanType
```

No purity guard. No `def` parameter needed (type-only check).

### Step 4: Add `isValueMultiTarget` and `getOrCreateValueInstance`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

```elm
isValueMultiTarget : Name -> MonoState -> Bool
isValueMultiTarget name state =
    List.any (\entry -> entry.defName == name) state.ctx.valueMulti
```

```elm
getOrCreateValueInstance : Name -> Mono.MonoType -> Substitution -> MonoState -> ( Name, MonoState )
```

Mirrors `getOrCreateLocalInstance` / `updateLocalMultiStack`:
1. Walks `state.ctx.valueMulti` to find the entry for `name`.
2. Computes `key = Mono.toComparableMonoType requestedType`.
3. If the key exists, returns the existing `freshName`.
4. Otherwise, creates `freshName = name ++ "$v" ++ String.fromInt (Dict.size entry.instances)`, records a `ValueInstanceInfo`, updates the stack.

Implement via a helper `updateValueMultiStack` that recurses through the stack list (same pattern as `updateLocalMultiStack`).

### Step 5: Wire `VarLocal` / `TrackedVarLocal` to check `isValueMultiTarget`

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

In `specializeExpr`, modify both `TOpt.VarLocal` and `TOpt.TrackedVarLocal` cases. Check `isValueMultiTarget` **before** `isLocalMultiTarget`:

```elm
TOpt.VarLocal name canType ->
    let
        monoType = Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
    in
    if isValueMultiTarget name state then
        let
            ( freshName, state1 ) =
                getOrCreateValueInstance name monoType subst state
        in
        ( Mono.MonoVarLocal freshName monoType, state1 )
    else if isLocalMultiTarget name state then
        -- existing code unchanged
        ...
    else
        ( Mono.MonoVarLocal name monoType, state )
```

Same pattern for `TOpt.TrackedVarLocal`.

No changes needed in the `TOpt.Call` fallback path — `r.fn 42` desugars to `Call (Access (VarLocal "r") "fn") [42]`, and `specializeExpr` on `VarLocal "r"` triggers value-multi instance creation via this step.

### Step 6: Modify the non-function `Let` branch

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

In `specializeExpr`, the `TOpt.Let def body canType` case dispatches on `defCanType`. The branch structure becomes:

```elm
case defCanType of
    Can.TLambda _ _ ->
        -- Function def: localMulti path (EXISTING, UNCHANGED)
        ...

    _ ->
        if shouldUseValueMulti defCanType then
            -- VALUE-MULTI PATH (NEW)
            ...
        else
            -- Non-function let: eager path (EXISTING, UNCHANGED)
            ...
```

The value-multi path:

1. **Push:** Build a `ValueMultiState` entry with `defName`, `defCanType`, `def`, `instances = Dict.empty`. Push onto `state.ctx.valueMulti`.
2. **Specialize body:** Call `specializeExpr body subst stateForBody`. No `varEnv` insertion for `defName` — uses will go through `isValueMultiTarget`.
3. **Pop & dispatch:**
   - Pop the top `valueMulti` entry from `stateAfterBody.ctx.valueMulti`.
   - **If `instances` is empty** (value never used):
     - Fall back to the existing eager non-function let behavior: `specializeDef def subst`, compute `defMonoType`, enrich subst, re-specialize body.
     - This mirrors the `localMulti` empty-instances fallback.
   - **If `instances` is non-empty:**
     - For each instance in `Dict.values topEntry.instances`:
       - `mergedSubst = TypeSubst.unifyExtend defCanType instance.monoType subst`
       - `( monoDef0, st1 ) = specializeDef def mergedSubst stAcc`
       - `monoDef = renameMonoDef instance.freshName monoDef0`
     - Register all instance names/types in `varEnv`.
     - Build nested `MonoLet` chain: `List.foldl (\def_ acc -> Mono.MonoLet def_ acc (Mono.typeOf acc)) monoBody instanceDefs`.
4. **Handle `[] ->` stack underflow:** Same crash/fallback as `localMulti`.

### Step 7: Update module exports

**File:** `compiler/src/Compiler/Monomorphize/State.elm`

Add `ValueInstanceInfo`, `ValueMultiState` to the `exposing` list.

### Step 8: Audit and update MONO_021 / MONO_024 test expectations

**Files:** `compiler/tests/TestLogic/Monomorphize/NoCEcoValueInUserFunctions*.elm`, `compiler/tests/TestLogic/Monomorphize/FullyMonomorphicNoCEcoValue*.elm`

This is a **required pre-merge checklist item**, not an optional follow-up:

1. Before coding, grep MONO_021/MONO_024 tests for cases involving:
   - `Record`/`Tuple` values with embedded lambdas,
   - Let-bound values later used as functions (e.g. record fields or tuple slots used as call targets).
2. After implementation, rerun all monomorphization tests.
3. Update expected outputs **only where types became more concrete** (e.g. `MErased` replaced by `MInt`). Do not weaken any existing passing expectations.

### Step 9: Add new tests

**File:** `compiler/tests/TestLogic/Monomorphize/` (new or existing test files)

Add test cases exercising the value-multi path:
1. **Record with identity lambda:** `let r = { fn = \x -> x } in r.fn 42` — closure type should be `MFunction [MInt] MInt`, not `MErased`.
2. **Record update with lambda:** `let r = { fn = \x -> 0 } in { r | fn = \x -> x }.fn 42` — concrete closure.
3. **Multiple uses at different types:** `let r = { fn = \x -> x } in (r.fn 42, r.fn "hello")` — two instances (`r$v0`, `r$v1`).
4. **Unused value-multi binding:** `let r = { fn = \x -> x } in 42` — falls back to eager path.
5. **Genuinely phantom:** Polymorphic container value with no constraining use — should still erase correctly to `MErased`.
