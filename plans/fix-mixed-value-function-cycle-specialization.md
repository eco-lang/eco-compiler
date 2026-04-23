# Fix mixed value+function cycle specialization

## 1. Current behavior and target behavior

### 1.1 Where cycles are specialized today

Typed-optimized globals can be `TOpt.Cycle names valueDefs funcDefs deps`. In
`Specialize.specializeNode`, cycles are dispatched to `specializeCycle`:

```elm
        TOpt.Cycle names valueDefs funcDefs _ ->
            specializeCycle names valueDefs funcDefs requestedMonoType state
```

`specializeCycle` decides which helper to use based on whether the cycle has
any functions and on `currentGlobal`:

```elm
specializeCycle :
    List Name
    -> List ( Name, TOpt.Expr MVarId )
    -> List (TOpt.Def MVarId)
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeCycle _ valueDefs funcDefs requestedMonoType state =
    case ( List.isEmpty funcDefs, state.ctx.currentGlobal ) of
        ( True, Just (Mono.Global requestedCanonical requestedName) ) ->
            specializeValueCycle
                requestedCanonical
                requestedName
                valueDefs
                requestedMonoType
                state

        ( True, Nothing ) ->
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Nothing ) ->
            ( Mono.MonoExtern requestedMonoType, state )

        ( False, Just (Mono.Global requestedCanonical requestedName) ) ->
            specializeFunctionCycle
                requestedCanonical
                requestedName
                valueDefs
                funcDefs
                requestedMonoType
                state

        ( _, Just (Mono.Accessor _) ) ->
            Utils.Crash.crash "Specialize.specializeCycle: Accessor should not appear in cycles"
```

- Value-only cycles go to `specializeValueCycle`.
- Any cycle with a non-empty `funcDefs` and a real current global goes to
  `specializeFunctionCycle`.

### 1.2 Value-only cycles already handled correctly

For value-only cycles we already do the right thing:

```elm
specializeValueCycle :
    IO.Canonical
    -> Name
    -> List ( Name, TOpt.Expr MVarId )
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeValueCycle requestedCanonical requestedName valueDefs requestedMonoType state =
    let
        maybeRequestedExpr =
            List.filter (\( n, _ ) -> n == requestedName) valueDefs
                |> List.head

        sharedSubst : Substitution
        sharedSubst =
            case maybeRequestedExpr of
                Just ( _, expr ) ->
                    let
                        canType =
                            TOpt.typeOf expr
                    in
                    Tuple.first (TypeSubst.unify state.ctx.mvarEnv canType requestedMonoType)

                Nothing ->
                    Dict.empty

        ( newNodes, stateAfter ) =
            List.foldl
                (specializeValueInCycle requestedCanonical requestedName requestedMonoType sharedSubst)
                ( state.accum.nodes, state )
                valueDefs

        requestedGlobal =
            Mono.Global requestedCanonical requestedName

        ( requestedSpecId, _ ) =
            Registry.getOrCreateSpecId requestedGlobal requestedMonoType Nothing stateAfter.accum.registry
    in
    case Array.get requestedSpecId newNodes |> Maybe.andThen identity of
        Just requestedNode ->
            ...
        Nothing ->
            ( Mono.MonoExtern requestedMonoType, ... )
```

The helper `specializeValueInCycle`:

- Registers a `SpecId` for each `(Name, Expr)` in the cycle.
- Uses `requestedMonoType` for the requested name and infers `monoTypeFromExpr`
  for others.
- Specializes the expression and writes a `Mono.MonoDefine` node into `nodes`.

### 1.3 Where the bug lives

For mixed cycles (both `valueDefs` and `funcDefs` non-empty) we go through
`specializeFunctionCycle`. Its current definition ignores `valueDefs` and only
specializes functions:

```elm
specializeFunctionCycle requestedCanonical requestedName _ funcDefs requestedMonoType state =
    ...
```

In the reproducer tests where `treeDecoder` / `listDecoder` / `nestedDecoder`
are in `valueDefs` and only helper functions are in `funcDefs`,
`maybeRequestedDef` is `Nothing`, `sharedSubst = Dict.empty`, and *no value* is
ever specialized for the requested global. The lookup falls through to
`Mono.MonoExtern`, which later codegens to a Unit-returning stub.

### 1.4 Target behavior for mixed cycles

We want a single algorithm for mixed cycles that:

- Derives a `sharedSubst` from whichever member is the requested entrypoint
  (function or value), using `TypeSubst.unifyExtend` so that information from
  either source enriches rather than overrides.
- Specializes all members of the SCC: every `(Name, Expr)` in `valueDefs` and
  every `TOpt.Def` in `funcDefs`.
- Ensures that if `requestedName` is in the SCC, its
  `(Global, requestedMonoType)` specialization always yields a real `MonoNode`
  (`MonoDefine` or `MonoTailFunc`), not `MonoExtern`.

## 2. Code changes in `Compiler/Monomorphize/Specialize.elm`

File: `compiler/src/Compiler/Monomorphize/Specialize.elm`

One localized change: rewrite `specializeFunctionCycle` so it

1. Binds `valueDefs` by name (no longer `_`).
2. Looks up the requested name in both `funcDefs` and `valueDefs`. By design
   (see §7.1) only one of these ever matches, but the code is written so that
   if both matched, information from both would be merged via `unifyExtend`.
3. Builds `sharedSubst` by seeding from the function def (if any) and
   `unifyExtend`-ing the value expr (if any).
4. Folds `specializeFunc` over `funcDefs`, then folds `specializeValueInCycle`
   over `valueDefs`, chaining the nodes/state through.

### 2.1 New `specializeFunctionCycle` implementation

Replace the existing definition of `specializeFunctionCycle` (the whole
declaration plus its body) with:

```elm
{-| Specialize a cycle that contains at least one function definition, by
creating separate nodes for each function in `funcDefs` AND each zero-arg value
in `valueDefs`.

This generalizes the previous function-only behavior to cover mixed
value+function SCCs. `specializeValueCycle` still handles pure-value SCCs.

  * `sharedSubst` is derived from the requested member, which may be either
    a function (in `funcDefs`) or a value (in `valueDefs`). The two sources
    are combined via `TypeSubst.unifyExtend` so neither overrides the other.
    In practice only one ever applies because a given top-level name is
    either a `Define` (value) or a `Def`/`TailDef` (function), never both
    (see specialize-cycle disjointness invariant).
  * All `funcDefs` are specialized via `specializeFunc`.
  * All `valueDefs` are specialized via `specializeValueInCycle`.

This guarantees that any requested global in the SCC (function or value) gets
a real MonoNode instead of falling back to MonoExtern.
-}
specializeFunctionCycle :
    IO.Canonical
    -> Name
    -> List ( Name, TOpt.Expr MVarId )
    -> List (TOpt.Def MVarId)
    -> Mono.MonoType
    -> MonoState
    -> ( Mono.MonoNode, MonoState )
specializeFunctionCycle requestedCanonical requestedName valueDefs funcDefs requestedMonoType state =
    let
        maybeRequestedDef =
            List.filter (defHasName requestedName) funcDefs
                |> List.head

        maybeRequestedExpr =
            List.filter (\( n, _ ) -> n == requestedName) valueDefs
                |> List.head

        -- Seed with the function-derived subst if the requested name is a
        -- function. If not, this stays empty and unifyExtend below will build
        -- the subst from the value expression alone.
        substFromFunc : Substitution
        substFromFunc =
            case maybeRequestedDef of
                Just def ->
                    Tuple.first
                        (TypeSubst.unify
                            state.ctx.mvarEnv
                            (getDefCanonicalType def)
                            requestedMonoType
                        )

                Nothing ->
                    Dict.empty

        -- Extend with value-derived bindings if the requested name is a value.
        -- Using unifyExtend mirrors how `specializeNode`'s TOpt.Define /
        -- TrackedDefine cases enrich substitutions.
        sharedSubst : Substitution
        sharedSubst =
            case maybeRequestedExpr of
                Just ( _, expr ) ->
                    Tuple.first
                        (TypeSubst.unifyExtend
                            state.ctx.mvarEnv
                            (TOpt.typeOf expr)
                            requestedMonoType
                            substFromFunc
                        )

                Nothing ->
                    substFromFunc

        -- Specialize all functions in the cycle under sharedSubst.
        ( nodesAfterFuncs, stateAfterFuncs ) =
            List.foldl
                (specializeFunc requestedCanonical requestedName requestedMonoType sharedSubst)
                ( state.accum.nodes, state )
                funcDefs

        -- Specialize all values in the cycle under the same sharedSubst.
        ( newNodes, stateAfter ) =
            List.foldl
                (specializeValueInCycle requestedCanonical requestedName requestedMonoType sharedSubst)
                ( nodesAfterFuncs, stateAfterFuncs )
                valueDefs

        requestedGlobal =
            Mono.Global requestedCanonical requestedName

        ( requestedSpecId, _ ) =
            Registry.getOrCreateSpecId requestedGlobal requestedMonoType Nothing stateAfter.accum.registry
    in
    case Array.get requestedSpecId newNodes |> Maybe.andThen identity of
        Just requestedNode ->
            ( requestedNode
            , { stateAfter
                | accum =
                    let
                        a =
                            stateAfter.accum
                    in
                    { a | nodes = newNodes }
              }
            )

        Nothing ->
            -- Should not occur once mixed cycles populate values: the
            -- requested name is guaranteed to be in `names` of the Cycle.
            -- Retain the MonoExtern fallback as a belt-and-braces guard.
            ( Mono.MonoExtern requestedMonoType
            , { stateAfter
                | accum =
                    let
                        a =
                            stateAfter.accum
                    in
                    { a | nodes = newNodes }
              }
            )
```

Where to paste: overwrite the current `specializeFunctionCycle` (declaration +
body) and leave `specializeFunc` and `specializeValueInCycle` unchanged; they
already do the right specialization and node insertion for individual members.

Fold order (functions first, then values) is semantically irrelevant for
correctness: `arrayHasNode` only returns true when a real `MonoNode` has been
written via `arraySetGrowing`, and there is no placeholder state. Either order
produces the same final nodes array, because specialization of a given
`(Global, MonoType)` is deterministic and idempotent against the
`arrayHasNode` short-circuit.

### 2.2 Why this fixes the four mixed-cycle tests

- **Test 1 / Test 4 (1 value + 1 function)**
  - SCC: `valueDefs = [ treeDecoder ]`, `funcDefs = [ branchBy ]`.
  - For `treeDecoder` as the requested global, `maybeRequestedDef = Nothing`,
    `maybeRequestedExpr = Just (treeDecoder, expr)`.
  - `sharedSubst` seeds from empty, then `unifyExtend`s with
    `TOpt.typeOf treeDecoderExpr` vs `requestedMonoType`.
  - `specializeFunc` specializes `branchBy`, `specializeValueInCycle`
    specializes `treeDecoder`.
  - `requestedSpecId` now points to a real `Mono.MonoDefine` node for
    `treeDecoder`, so we never hit `MonoExtern`.

- **Test 2 (1 value + 2 functions)**
  - SCC: `valueDefs = [ listDecoder ]`,
    `funcDefs = [ decideDispatch, continueList ]`.
  - `sharedSubst` is built from `listDecoder`'s expr type when `listDecoder`
    is the entrypoint.
  - Both functions and the value get real nodes. No stub, no Unit constant.

- **Test 3 (2 values + 1 function)**
  - SCC: `valueDefs = [ treeDecoder, nestedDecoder ]`,
    `funcDefs = [ tagDispatch ]`.
  - If entrypoint is `treeDecoder`, `sharedSubst` is derived from its expr.
  - `specializeValueInCycle` also specializes `nestedDecoder` in the same
    pass.
  - Both decoders get real nodes rather than falling through.

In all these, MLIR codegen now sees a `MonoDefine` or `MonoTailFunc` node for
the decoders, not `MonoExtern`, so it no longer emits a `func.func` with a
Unit-returning stub for those globals. The `generateStubValue` path remains in
place but only for truly extern things (ports, kernels, unresolved links),
which is what it was designed for.

## 3. Optional: tighten invariants to guard against regressions

Kernel, manager, and port nodes are handled *before* the `TOpt.Cycle` case in
`specializeNode` (`TOpt.Kernel → MonoExtern`, `TOpt.Manager → MonoManagerLeaf`,
`TOpt.PortIncoming/PortOutgoing → MonoPortIncoming/MonoPortOutgoing`). Only
`TOpt.Cycle` routes to `specializeCycle`, which in turn only dispatches to
`specializeValueCycle` / `specializeFunctionCycle`. After this fix, both of
those must produce `MonoDefine` or `MonoTailFunc` nodes for cycle members.

The right invariant is therefore straightforward:

> No specialization path that goes through `specializeCycle` may produce
> `Mono.MonoExtern` for a cycle member. Equivalently: for every SpecId
> registered for a `Global (canonical, name)` where `name` appears in some
> `TOpt.Cycle`'s `names`, the resulting `MonoNode` must be `MonoDefine` or
> `MonoTailFunc`.

No need to carve out kernel/manager/port exceptions — they are not represented
as cycles in this IR.

Easiest to test at the MonoGraph level: iterate the registry entries derived
from cycle members and assert none are `MonoExtern`.

## 4. No changes needed in MLIR backend

Do not change:

- `Compiler.Generate.MLIR.Functions.generateExtern` / `generateStubValue`
  (they are correct but now only hit for genuine externs).
- JSON representation / decoder ABI docs — they're consistent with using Unit
  as an embedded constant, which remains valid for values that are
  *semantically* unit.

The main backend symptom (Unit being passed where a `Decoder` or `Parser`
value is expected) goes away once monomorphization no longer produces
`MonoExtern` for those globals.

## 5. Summary

Bug: Mixed value+function recursive cycles route through
`specializeFunctionCycle`, which ignores `valueDefs`, so zero-arg values in
the SCC (such as various decoders) are never monomorphized and fall back to
`MonoExtern`. The MLIR backend then emits stubs returning embedded Unit
constants, which blow up when treated as heap pointers.

Fix: Make `specializeFunctionCycle` handle both `funcDefs` and `valueDefs`:

- Derive `sharedSubst` from either the requested function def or the
  requested value expr, combined via `TypeSubst.unifyExtend` so both sources
  contribute when applicable.
- Fold `specializeFunc` over `funcDefs` and `specializeValueInCycle` over
  `valueDefs` in a single pass over the SCC.
- Leave `specializeValueCycle` as-is for pure-value SCCs — minimum blast
  radius. A later cleanup may unify both paths into a single
  `specializeMixedCycle`, but that is out of scope for this fix.

## 6. Build and verification steps

1. Edit `compiler/src/Compiler/Monomorphize/Specialize.elm` as described in §2.1.
2. Front-end check:
   `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1`.
3. E2E build + test:
   `cmake --build build --target full`.
   Per project docs, `full` is the right target for compiler changes — it does
   a clean rebuild and avoids stale `.mlir`. No manual `build-self.sh` /
   `build-verify.sh` run is needed for the new E2E tests; `full` rebuilds the
   XHR compiler and re-runs all MLIR pipelines.
4. Targeted test pass:
   `TEST_FILTER=Mixed cmake --build build --target full`. All four of
   `BytesDecoderMixedValueFunctionCycleTest`,
   `BytesDecoderMixedCycleTwoFunctionsTest`,
   `BytesDecoderMixedCycleTwoValuesTest`,
   `JsonDecoderMixedValueFunctionCycleTest` should pass.
5. (Optional) Re-attempt stage 7 of `guides/bootstrap.md` and confirm
   `Compiler.Json.Decode.pValue` no longer resolves to a Unit stub; the
   bootstrap should progress past `parseAndValidateOutline ->
   Json.Decode.fromByteString`.
6. Update `project_mixed_cycle_bug.md` memory with the fix and any new stress
   deltas.

## 7. Resolved design questions

### 7.1 SpecId allocation / value-vs-function name collisions

Specialization keys are `(Global, MonoType, Maybe LambdaId)`. `Global` is
`Global IO.Canonical Name` or `Accessor Name`; top-level definitions are
unique per `(module, name)`. Inside a `TOpt.Cycle`, `valueDefs` and `funcDefs`
are disjoint by construction: a top-level name is either a `Define` (zero-arg,
goes into `valueDefs`) or a `Def`/`TailDef` (function, goes into `funcDefs`).
There is no "value and function with same name" case, so the new
`maybeRequestedDef` / `maybeRequestedExpr` pair yields at most one `Just`.
Sibling SCCs have distinct `Global`s, so no cross-cycle SpecId collision is
possible.

### 7.2 `sharedSubst` composition

Combine substitutions with `TypeSubst.unifyExtend` rather than picking one,
mirroring how `specializeNode`'s `TOpt.Define` / `TrackedDefine` branches
enrich substitutions. In this cycle code, one of the two sources is always
empty (§7.1), so the effect is equivalent to "use whichever is present" —
but the `unifyExtend` form is more robust to future edge cases and consistent
with existing monomorphizer style.

### 7.3 Fold order and `arrayHasNode` semantics

`arrayHasNode` is:

```elm
arrayHasNode index arr =
    case Array.get index arr of
        Just (Just _) -> True
        _ -> False
```

There is no placeholder node representation. Both `specializeFunc` and
`specializeValueInCycle` only write `Just monoNode` via `arraySetGrowing`,
and both short-circuit on `arrayHasNode`. Specialization for a given
`(Global, MonoType)` is deterministic and idempotent, so the order in which
`funcDefs` and `valueDefs` are folded does not matter for correctness. The
plan folds functions first, then values, purely for readability.

### 7.4 Minimal fix vs unified mixed-cycle refactor

Extending `specializeFunctionCycle` is the minimum-blast-radius change.
`specializeValueCycle` stays untouched for pure-value SCCs. A refactor to a
single `specializeMixedCycle` that always handles both lists is possible but
broadens the change surface and is not required to fix the miscompile.
Deferred as potential cleanup, not part of this fix.

### 7.5 Build / bootstrap steps required

Per project docs: for compiler changes, `cmake --build build --target full`
is the right target — it performs a clean rebuild and runs the E2E tests,
avoiding stale `.mlir` files. You do NOT need to manually re-run
`scripts/build-self.sh` or `scripts/build-verify.sh` to test this change
against the new E2E tests; `full` covers rebuilding the XHR compiler and
running the tests through `eco-boot-native`. Those scripts matter for
producing a self-hosted binary outside the normal test harness, which is a
separate activity (stage 7 of the bootstrap).

### 7.6 Invariant phrasing

The assertable invariant is simple: "no specialization path through
`specializeCycle` may produce `Mono.MonoExtern`." Kernel / manager / port
nodes are handled on separate branches of `specializeNode` before the
`TOpt.Cycle` case, so they are not cycle members and do not need carve-outs
in the invariant.

### 7.7 Zero-arg, function-typed top-level entries in `valueDefs`

Top-level "values" whose canonical type is a function type (e.g. zero-arg
bindings whose body is a lambda) appear as `TOpt.Define` nodes and therefore
live in `valueDefs`, not `funcDefs`. `specializeNode` on a `Define` directly
produces a `MonoDefine` whose `MonoType` may be `MFunction`; GlobalOpt phase
1 is responsible for wrapping such function-typed `MonoDefine` nodes into
proper callable closures. That wrapping is the one and only wrapping — there
is no parallel path that would also treat them as `funcDefs`. Routing them
through `specializeValueInCycle` in a mixed cycle is therefore correct, and
no double-wrapping risk exists.

## 8. Expected test outcomes

After the change, the following tests should all PASS (they currently crash):

- `test/elm-bytes/src/BytesDecoderMixedValueFunctionCycleTest.elm`
- `test/elm-bytes/src/BytesDecoderMixedCycleTwoFunctionsTest.elm`
- `test/elm-bytes/src/BytesDecoderMixedCycleTwoValuesTest.elm`
- `test/elm-json/src/JsonDecoderMixedValueFunctionCycleTest.elm`

Stage 7 of the bootstrap (`bin/eco-compiler make …` on its own source) should
also progress past the `Builder.Elm.Outline.parseAndValidateOutline ->
Compiler.Json.Decode.fromByteString` call chain that currently trips the
`eco_resolve_hptr` assertion on the Unit stub for
`Compiler.Json.Decode.pValue`.
