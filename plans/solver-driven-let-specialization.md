# Solver-Driven Specialization for Let-Bound Functions

## Problem Statement

Currently, `specializeDefForInstance` (Specialize.elm:1265) assigns parameter types from the call-site `info.monoType` but reuses the **outer** `LocalView` for specializing the body. This means inner expressions that call `resolveType view meta` see unresolved type variables for the let-bound function's own quantified variables.

**Example failure case:**
```elm
foo : List Int -> Int
foo xs =
    let
        helper : (a -> a) -> a -> a
        helper f x = f x
    in
    helper (\x -> x + 1) 0
```
When `helper` is called at type `(Int -> Int) -> Int -> Int`, the parameters get assigned `Int` correctly via `info.monoType`. But inside `helper`'s body, `resolveType view { tvar = bodyTvar }` for sub-expressions like `f x` still sees `a` as an unresolved rigid variable, because the outer `view` was unified with the *enclosing* function's annotation, not with `helper`'s annotation.

**Root cause:** `specializeDefForInstance` ignores `funcMeta.tvar` entirely (lines 1272, 1307) and never creates a nested solver unification scope.

Similarly, `specializeCycle` (line 1402) uses `withLocalUnification snapshot [] []` — an empty unification scope — so polymorphic mutually-recursive cycle functions also lack solver-driven specialization.

## Design Principle

From the monomorphization design: "all substitution happens inside the HM solver via local unification." The `SolverSnapshot.specializeFunction` mechanism already does this correctly for global definitions (`specializeDefineNode` at line 142). The gap is in let-bound polymorphic functions and cycles.

**Encapsulation rule** (per design review): `LocalView` stays narrow (`{ typeOf, monoTypeOf }`). All solver logic — including nested unification — lives inside `SolverSnapshot.elm`. Consumers in `Specialize.elm` call only higher-level helpers.

## What Already Exists

`SolverSnapshot.elm` has all required infrastructure:
- `specializeFunction` (line 188): copies snapshot state, calls `walkAndUnify`, builds `LocalView`
- `walkAndUnify` (line 299): recursively walks solver graph, relaxes rigid vars, unifies with MonoType
- `monoTypeToVar` (line 507): projects MonoType back into solver variables
- `relaxRigidVar` (line 645): converts rigid vars to flex vars for unification
- `buildLocalView` (line 219): creates `LocalView` with `typeOf`/`monoTypeOf` closures

## Key Challenge: Nested Scoping

`specializeFunction` always starts from `snap.state` (the *original* snapshot). For a let-bound function inside an already-specialized outer function, we need:
1. The outer function's unifications (e.g., outer `a = Int` for captured variables)
2. **Plus** the inner function's unifications (e.g., `helper`'s own `b = Int`)

These must compose: if `helper` captures a variable `x` whose type involves the outer `a`, the inner view must see `a = Int` (from the outer scope) AND `b = Int` (from the inner scope).

Since `specializeFunction` copies `snap.state` fresh each time, calling it separately for the inner function would discard outer unifications.

## Solution: Spec Stack + `specializeChained`

### Core idea

Thread a **spec stack** — `List (TypeVar, MonoType)` — through `MonoDirectState`. Each entry records one (annotVar, requestedKey) pair from an enclosing specialization scope.

When entering a nested scope (let-bound function, cycle function), push the new pair onto the stack and call `specializeChained` in `SolverSnapshot.elm`, which replays ALL accumulated unifications from the original snapshot state in a single pass. This produces a `LocalView` that correctly reflects all ancestor + current unifications.

### Why replay is safe

- `walkAndUnify` is idempotent on already-unified variables (walking a structure that already matches the target is a no-op).
- Replaying N unifications on the snapshot is O(N × type_size), but nesting depth is typically 1–3 in practice.
- The original snapshot is never mutated (Elm immutability).
- `defaultNumericVarsToInt` is idempotent.

## Implementation Plan

### Step 1: Add `specStack` to `MonoDirectState`

**File:** `compiler/src/Compiler/MonoDirect/State.elm`

```elm
type alias MonoDirectState =
    { ...existing fields...
    , specStack : List ( SolverSnapshot.TypeVar, Mono.MonoType )
    }
```

Initialize to `[]` in `initState`.

`SolverSnapshot.TypeVar` is already accessible since State.elm imports `SolverSnapshot` and `IO`.

### Step 2: Add `specializeChained` to `SolverSnapshot.elm`

**File:** `compiler/src/Compiler/Type/SolverSnapshot.elm`

```elm
specializeChained : SolverSnapshot -> List ( TypeVar, MonoType ) -> (LocalView -> a) -> a
specializeChained snap pairs callback =
    let
        localState =
            snapshotToIoState snap.state

        stateAfterAll =
            List.foldl
                (\( tv, mt ) st -> walkAndUnify st tv mt)
                localState
                pairs

        stateAfterDefault =
            defaultNumericVarsToInt stateAfterAll

        view =
            buildLocalView stateAfterDefault
    in
    callback view
```

The pairs are applied in order (outermost first, innermost last). Since the list is built by consing (most recent first), callers should pass `List.reverse state.specStack`.

Alternatively, we can use `List.foldr` and keep the stack in cons order — pick whichever is clearer:
```elm
-- If specStack is [ (inner, keyInner), (outer, keyOuter) ] (cons order):
List.foldr (\( tv, mt ) st -> walkAndUnify st tv mt) localState pairs
```

### Step 3: Push spec stack in `specializeDefineNode`

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

Currently:
```elm
specializeDefineNode snapshot expr meta requestedMonoType state =
    case meta.tvar of
        Just annotVar ->
            SolverSnapshot.specializeFunction snapshot annotVar requestedMonoType
                (\view -> ...specializeExpr view snapshot expr state...)
```

Change to push `(annotVar, requestedMonoType)` onto the spec stack before entering the body:
```elm
specializeDefineNode snapshot expr meta requestedMonoType state =
    case meta.tvar of
        Just annotVar ->
            SolverSnapshot.specializeFunction snapshot annotVar requestedMonoType
                (\view ->
                    let
                        stateWithPush =
                            { state | specStack = ( annotVar, requestedMonoType ) :: state.specStack }

                        ( monoExpr, state1 ) =
                            specializeExpr view snapshot expr stateWithPush

                        statePopped =
                            { state1 | specStack = state.specStack }
                    in
                    ( Mono.MonoDefine monoExpr (Mono.typeOf monoExpr), statePopped )
                )
```

Note: the existing `specializeFunction` call creates the correct view for this level. The stack entry is for *descendant* scopes to replay.

### Step 4: Modify `specializeDefForInstance` to use nested specialization

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

For `TOpt.Function params bodyExpr funcMeta` (line 1272):

```elm
TOpt.Function params bodyExpr funcMeta ->
    case funcMeta.tvar of
        Just tvar ->
            let
                -- Push inner specialization onto stack
                innerStack =
                    ( tvar, info.monoType ) :: state.specStack

                -- Replay all unifications (outer + inner)
                snapshot =
                    state.snapshot
            in
            SolverSnapshot.specializeChained snapshot innerStack
                (\innerView ->
                    let
                        ( paramTypes, _ ) =
                            Closure.flattenFunctionType info.monoType

                        monoParams =
                            List.map2 ...  -- same as before

                        state1 =
                            { state
                                | varEnv = State.pushFrame state.varEnv
                                , specStack = innerStack
                            }

                        state2 =
                            List.foldl ... state1 monoParams  -- bind params

                        ( monoBody, state3 ) =
                            specializeExpr innerView snapshot bodyExpr state2

                        state4 =
                            { state3
                                | varEnv = State.popFrame state3.varEnv
                                , specStack = state.specStack  -- restore
                            }

                        -- ...build closureExpr as before...
                    in
                    ( Mono.MonoDef info.freshName closureExpr, state4 )
                )

        Nothing ->
            if isMonomorphicCanType funcMeta.tipe then
                -- Monomorphic: current behavior (use outer view)
                ...existing code...
            else
                Utils.Crash.crash
                    ("MonoDirect.specializeDefForInstance: missing solver tvar for polymorphic type "
                        ++ Debug.toString funcMeta.tipe
                    )
```

Same pattern for `TOpt.TrackedFunction` (line 1307).

For the catch-all `_ ->` branch (line 1349), keep current behavior.

### Step 5: Fix `specializeCycle` to use solver-driven specialization

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

Currently (line 1402):
```elm
SolverSnapshot.withLocalUnification snapshot [] []
```

Change to use `specializeChained` with the current spec stack. For the requested function in the cycle, find its annotation var and add it to the stack:

```elm
Just (Mono.Global requestedCanonical requestedName) ->
    let
        -- Find the requested function's tvar from funcDefs
        requestedTvar =
            List.filterMap
                (\funcDef ->
                    let ( name, _, tvar ) = funcDefInfo funcDef
                    in if name == requestedName then tvar else Nothing
                )
                funcDefs
                |> List.head

        cycleStack =
            case requestedTvar of
                Just tvar ->
                    ( tvar, requestedMonoType ) :: state.specStack

                Nothing ->
                    state.specStack
    in
    SolverSnapshot.specializeChained snapshot cycleStack
        (\view -> ...existing cycle body...)
```

This ensures that `resolveType view { tvar = defTvar }` inside the cycle sees the specialized types.

### Step 6: Handle `specializeLetFuncDef` single-instance path

**File:** `compiler/src/Compiler/MonoDirect/Specialize.elm`

The single-instance fallback (lines 1177–1195) calls `specializeExpr view snapshot defExpr` with the outer view. If `defExpr` is a `TOpt.Function` with its own polymorphic tvar, the body needs nested scoping.

Since the single-instance path doesn't have a call-site `info.monoType`, it uses `resolveType view meta` for the function's type (which gives the type as seen through the outer unification). This is correct for functions whose polymorphism is fully determined by the outer scope, but for independently polymorphic let-functions with no calls (dead code), it's acceptable to use the outer view.

**Action:** No change needed for the single-instance fallback. If there are no calls, the function is dead code and its types don't matter. If there IS a call, it goes through the multi-instance path (`specializeDefForInstance`), which Step 4 fixes.

### Step 7: Add concrete test case

Add an Elm module exercising the `myFoldl` pattern:

```elm
module PolyLetSpec exposing (..)

myFoldl : (a -> b -> b) -> b -> List a -> b
myFoldl f acc xs =
    case xs of
        [] -> acc
        y :: ys -> myFoldl f (f y acc) ys

useInt : List Int -> Int
useInt xs =
    myFoldl (\x acc -> acc + x) 0 xs
```

Also add a case with a polymorphic let-bound helper:
```elm
withHelper : Int -> Int
withHelper n =
    let
        apply : (a -> a) -> a -> a
        apply f x = f x
    in
    apply (\x -> x + 1) n
```

Wire into E2E tests (MonoDirectComparisonTest or similar) to verify:
- Accumulator parameter in specialized `myFoldl` is `MInt` (not `MErased` or `MVar`)
- `apply`'s body sees `a = Int` throughout
- Full pipeline produces correct native output

### Step 8: Run tests

```bash
cmake --build build --target check
cd compiler && npx elm-test-rs --fuzz 1
```

## Files Changed

| File | Change |
|------|--------|
| `compiler/src/Compiler/MonoDirect/State.elm` | Add `specStack : List ( TypeVar, MonoType )` field, initialize to `[]` |
| `compiler/src/Compiler/Type/SolverSnapshot.elm` | Add `specializeChained` function |
| `compiler/src/Compiler/MonoDirect/Specialize.elm` | Push/pop spec stack in `specializeDefineNode`; use `specializeChained` in `specializeDefForInstance` and `specializeCycle` |

## Risks and Considerations

1. **Performance of replay**: Each nested scope replays ALL ancestor unifications from scratch. With N nesting levels and type sizes T, this is O(N² × T). In practice N ≤ 3, so this is negligible. If profiling ever shows this as a hotspot, the alternative is the `SpecScope` opaque-type approach where intermediate IO states are threaded directly.

2. **`defaultNumericVarsToInt` is idempotent**: Called on every `specializeChained` invocation. Since it only converts `FlexSuper Number` → `Structure Int`, and the first invocation already converts all such vars, subsequent calls are no-ops on those descriptors.

3. **Spec stack save/restore discipline**: The stack must be restored after each scope exit. Since `MonoDirectState` is threaded through and returned, forgetting to restore would pollute sibling scopes. The plan explicitly shows save/restore at each push site.

4. **Crash on polymorphic + no tvar**: Consistent with `specializeDefineNode`'s existing behavior. Prevents silent production of wrong types.

5. **`funcDefInfo` returns `Nothing` for `TOpt.Def`**: In cycles, non-TailDef functions don't have tvars. For these, the cycle's existing behavior (empty unification) is preserved. If this turns out to be a source of bugs, `requireTVar`-style enforcement can be added later, but that's a broader change to the TOpt representation.

6. **Ordering of pairs in spec stack**: Pairs are consed (innermost first). `specializeChained` should process outermost first for correct incremental unification. Use `List.foldl` on the reversed list, or `List.foldr` on the cons-order list.
