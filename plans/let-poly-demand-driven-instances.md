# Plan: Demand-Driven Local Multi-Specialization Instances

## Problem

The current local `let` multi-specialization computes instance types eagerly via
`collectLocalInstantiations`, which walks the body AST under an **outer** substitution
before specialization. This can produce instance types that disagree with what call
sites actually compute during `specializeExpr`, leading to:

- Polymorphic-vs-specialized type mismatches
- "lookupVar: unbound variable" crashes when the plain `defName` is referenced but only
  renamed instances were emitted

## Solution

Compute instances **on demand** at each call site during body specialization, using the
same `callSubst` + `funcMonoType` values that the call site already computes. This makes
instance types and call-site types agree **by construction**.

### Architecture

1. Add `localMulti : Maybe LocalMultiState` to `MonoState` — per-let state tracking
   discovered instances.
2. At `TOpt.Let` for function defs: install a fresh `localMulti` context before
   specializing the body; after body specialization, read out the collected instances and
   clone the def once per instance.
3. At `TOpt.Call` fallback: when inside a `localMulti` context and the callee is a
   `VarLocal`/`TrackedVarLocal` matching `defName`, allocate/reuse an instance via
   `getOrCreateLocalInstance` and rewrite the call immediately.
4. At `TOpt.VarLocal`/`TOpt.TrackedVarLocal` (non-call position): same interception for
   higher-order uses (e.g., `List.map double xs`).
5. At `renameMonoDef`: extend to also rename self tail-calls inside `MonoTailDef` bodies,
   so each cloned instance's internal `MonoTailCall` targets its own instance name.
6. Remove all now-unused collect/rewrite infrastructure.

---

## Steps

### Step 1: Extend `MonoState` with per-let local-instance state

**File:** `compiler/src/Compiler/Monomorphize/State.elm`

**1a.** Add new type aliases after `VarTypes` (line ~63):

```elm
type alias LocalInstanceInfo =
    { freshName : Name
    , monoType : Mono.MonoType
    , subst : Substitution
    }

type alias LocalMultiState =
    { defName : Name
    , instances : Dict (List String) LocalInstanceInfo
    }
```

No new imports needed — `Name`, `Mono`, `Dict`, `Substitution` are already in scope.

**1b.** Add `localMulti` field to `MonoState` (line 37-48):

```elm
, localMulti : Maybe LocalMultiState
```

**1c.** Initialize `localMulti = Nothing` in `initState` (line 72-83).

**1d.** Export `LocalInstanceInfo` and `LocalMultiState` — add them to the `exposing`
clause of `State.elm` and to the import in `Specialize.elm`.

### Step 2: Add `getOrCreateLocalInstance` helper

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

Add near the existing `LocalFunInstance` type (line ~55):

```elm
getOrCreateLocalInstance :
    Mono.MonoType
    -> Substitution
    -> MonoState
    -> ( Name, MonoState )
getOrCreateLocalInstance funcMonoType callSubst state =
    case state.localMulti of
        Nothing ->
            Utils.Crash.crash
                "Specialize.getOrCreateLocalInstance: no localMulti in state"

        Just localState ->
            let
                key =
                    Mono.toComparableMonoType funcMonoType
            in
            case Dict.get identity key localState.instances of
                Just info ->
                    ( info.freshName, state )

                Nothing ->
                    let
                        freshIndex =
                            Dict.size localState.instances

                        freshName =
                            localState.defName ++ "$" ++ String.fromInt freshIndex

                        newInfo =
                            { freshName = freshName
                            , monoType = funcMonoType
                            , subst = callSubst
                            }

                        newInstances =
                            Dict.insert identity key newInfo localState.instances

                        newLocalState =
                            { localState | instances = newInstances }
                    in
                    ( freshName, { state | localMulti = Just newLocalState } )
```

**Key:** keyed by `Mono.toComparableMonoType`, same as the old `typeKey`.

### Step 3: Intercept `VarLocal`/`TrackedVarLocal` for higher-order uses

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm` (lines 596-608)

Replace the `TOpt.VarLocal` and `TOpt.TrackedVarLocal` branches to intercept references
to the current `defName` when inside a `localMulti` context. This covers higher-order
uses like `List.map double xs` where the function is passed as a value, not called
directly.

```elm
        TOpt.VarLocal name canType ->
            let
                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
            in
            case state.localMulti of
                Just localState ->
                    if name == localState.defName then
                        let
                            ( freshName, state1 ) =
                                getOrCreateLocalInstance monoType subst state
                        in
                        ( Mono.MonoVarLocal freshName monoType, state1 )

                    else
                        ( Mono.MonoVarLocal name monoType, state )

                Nothing ->
                    ( Mono.MonoVarLocal name monoType, state )

        TOpt.TrackedVarLocal _ name canType ->
            let
                monoType =
                    Mono.forceCNumberToInt (TypeSubst.applySubst subst canType)
            in
            case state.localMulti of
                Just localState ->
                    if name == localState.defName then
                        let
                            ( freshName, state1 ) =
                                getOrCreateLocalInstance monoType subst state
                        in
                        ( Mono.MonoVarLocal freshName monoType, state1 )

                    else
                        ( Mono.MonoVarLocal name monoType, state )

                Nothing ->
                    ( Mono.MonoVarLocal name monoType, state )
```

**Rationale:** The old code's `rewriteLocalCalls` handled `MonoVarLocal` (not just
calls), so it did rewrite non-call references. This preserves that behavior within the
demand-driven design.

### Step 4: Modify `TOpt.Call` fallback to use per-let instances

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm` (lines 837-870)

Replace the `_ ->` fallback branch. After computing `callSubst`, `funcMonoType`,
`paramTypes`, `monoArgs`, and `resultMonoType` (all unchanged), add a `case` on
`( state2.localMulti, func )`:

- **`( Just localState, TOpt.VarLocal name _ )` where `name == localState.defName`:**
  Call `getOrCreateLocalInstance funcMonoType callSubst state2`, rewrite callee to
  `Mono.MonoVarLocal freshName funcMonoType`.

- **`( Just localState, TOpt.TrackedVarLocal _ name _ )` where `name == localState.defName`:**
  Same as above.

- **Otherwise:** Fall through to existing behavior (`specializeExpr func callSubst state2`).

**Important:** Remove the existing `( monoFunc, state3 ) = specializeExpr func callSubst state2`
from the shared `let` block — it now only runs in the non-instance branch.

**Note on Call vs VarLocal interception:** When a `TOpt.Call` has a `VarLocal` callee
matching `defName`, the Call fallback handles it (with the unified `callSubst` and
`funcMonoType` from argument unification). The Step 3 VarLocal interception would NOT
fire for this case because `specializeExpr func callSubst state2` is skipped when we
take the instance branch — the callee is rewritten directly without recursing into
`specializeExpr` for the func.

### Step 5: Replace `TOpt.Let` `Can.TLambda` branch with demand-driven logic

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm` (lines 907-1004)

Replace the entire `Can.TLambda _ _ ->` branch:

1. Save `oldLocalMulti = state.localMulti`.
2. Install fresh context: `{ state | localMulti = Just { defName = defName, instances = Dict.empty } }`.
3. Specialize the body: `specializeExpr body subst stateForBody` → `( monoBody, stateAfterBody )`.
4. Read `stateAfterBody.localMulti`:
   - **Empty instances (or Nothing):** Fall back to single-instance behavior — `specializeDef def subst`,
     register `defName` in `varTypes`, wrap in `MonoLet`. Restore `oldLocalMulti`.
   - **Non-empty instances:** For each instance:
     - `specializeDef def (Dict.union info.subst subst)` → rename to `info.freshName`.
     - Register `info.freshName` → `info.monoType` in `varTypes`.
     - Build nested `MonoLet` chain wrapping `monoBody`.
     - Restore `oldLocalMulti`.

**Nesting support:** The save/restore pattern (`oldLocalMulti` → install fresh →
restore after) naturally supports nested function-typed lets. Each inner let gets its own
`localMulti` context while its body is specialized, and the outer context is restored
when the inner let completes. This gives one active multi-specialization context per let
level. If truly simultaneous multi-specialization across nesting levels is needed later,
`localMulti` can be upgraded to a stack (`List LocalMultiState`), but single-level-at-a-time
suffices for now.

### Step 6: Extend `renameMonoDef` for self tail-call rewriting

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm` (lines 2159-2165)

The old `rewriteLocalCalls` rewrote `MonoTailCall` names via `findInstanceByName`. In
the new design, tail-call rewriting is handled at clone time: when `renameMonoDef` clones
a `MonoTailDef`, it also traverses the body to rename `MonoTailCall oldName` →
`MonoTailCall newName`.

**6a.** Modify `renameMonoDef`:

```elm
renameMonoDef : Name -> Mono.MonoDef -> Mono.MonoDef
renameMonoDef newName def =
    case def of
        Mono.MonoDef _ expr ->
            Mono.MonoDef newName expr

        Mono.MonoTailDef oldName args expr ->
            let
                renamedBody =
                    renameTailCalls oldName newName expr
            in
            Mono.MonoTailDef newName args renamedBody
```

**6b.** Add `renameTailCalls` helper — a targeted tree walk that only renames
`MonoTailCall` references from `oldName` to `newName`:

```elm
renameTailCalls : Name -> Name -> Mono.MonoExpr -> Mono.MonoExpr
renameTailCalls oldName newName expr =
    case expr of
        Mono.MonoTailCall name args resultType ->
            Mono.MonoTailCall
                (if name == oldName then newName else name)
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) args)
                resultType

        Mono.MonoCall region func args resultType callInfo ->
            Mono.MonoCall region
                (renameTailCalls oldName newName func)
                (List.map (renameTailCalls oldName newName) args)
                resultType
                callInfo

        Mono.MonoIf branches final resultType ->
            Mono.MonoIf
                (List.map (\( c, t ) -> ( renameTailCalls oldName newName c, renameTailCalls oldName newName t )) branches)
                (renameTailCalls oldName newName final)
                resultType

        Mono.MonoLet def body resultType ->
            let
                newDef =
                    case def of
                        Mono.MonoDef n bound ->
                            Mono.MonoDef n (renameTailCalls oldName newName bound)

                        Mono.MonoTailDef n params bound ->
                            Mono.MonoTailDef
                                (if n == oldName then newName else n)
                                params
                                (renameTailCalls oldName newName bound)
            in
            Mono.MonoLet newDef (renameTailCalls oldName newName body) resultType

        Mono.MonoClosure info body closureType ->
            Mono.MonoClosure info (renameTailCalls oldName newName body) closureType

        Mono.MonoList region items t ->
            Mono.MonoList region (List.map (renameTailCalls oldName newName) items) t

        Mono.MonoTupleCreate region items t ->
            Mono.MonoTupleCreate region (List.map (renameTailCalls oldName newName) items) t

        Mono.MonoRecordCreate fields t ->
            Mono.MonoRecordCreate
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) fields)
                t

        Mono.MonoRecordUpdate record updates t ->
            Mono.MonoRecordUpdate
                (renameTailCalls oldName newName record)
                (List.map (\( n, e ) -> ( n, renameTailCalls oldName newName e )) updates)
                t

        Mono.MonoRecordAccess record fieldName t ->
            Mono.MonoRecordAccess (renameTailCalls oldName newName record) fieldName t

        Mono.MonoDestruct destructor body t ->
            Mono.MonoDestruct destructor (renameTailCalls oldName newName body) t

        Mono.MonoCase scrutName scrutVar decider jumps t ->
            Mono.MonoCase scrutName scrutVar
                (renameTailCallsDecider oldName newName decider)
                (List.map (\( i, e ) -> ( i, renameTailCalls oldName newName e )) jumps)
                t

        -- Leaf nodes: unchanged
        Mono.MonoLiteral _ _ -> expr
        Mono.MonoVarLocal _ _ -> expr
        Mono.MonoVarGlobal _ _ _ -> expr
        Mono.MonoVarKernel _ _ _ _ -> expr
        Mono.MonoUnit -> expr
```

**6c.** Add `renameTailCallsDecider` and `renameTailCallsChoice` helpers to traverse
into `MonoCase` deciders (tail calls can appear inside `Inline` leaves):

```elm
renameTailCallsDecider : Name -> Name -> Mono.Decider Mono.MonoChoice -> Mono.Decider Mono.MonoChoice
renameTailCallsDecider oldName newName decider =
    case decider of
        Mono.Leaf choice ->
            Mono.Leaf (renameTailCallsChoice oldName newName choice)

        Mono.Chain tests success failure ->
            Mono.Chain tests
                (renameTailCallsDecider oldName newName success)
                (renameTailCallsDecider oldName newName failure)

        Mono.FanOut path edges fallback ->
            Mono.FanOut path
                (List.map (\( test, d ) -> ( test, renameTailCallsDecider oldName newName d )) edges)
                (renameTailCallsDecider oldName newName fallback)


renameTailCallsChoice : Name -> Name -> Mono.MonoChoice -> Mono.MonoChoice
renameTailCallsChoice oldName newName choice =
    case choice of
        Mono.Inline e ->
            Mono.Inline (renameTailCalls oldName newName e)

        Mono.Jump i ->
            Mono.Jump i
```

**How this works with multi-specialization:** In the function-let branch (Step 5), when
we build clones for each instance:

```elm
( monoDef0, st1 ) = specializeDef def mergedSubst stAcc
monoDef = renameMonoDef info.freshName monoDef0
```

If `def` is a `TOpt.TailDef`, `specializeDef` produces `Mono.MonoTailDef oldName args body`
where `body` contains `MonoTailCall oldName ...` for self-recursion. The extended
`renameMonoDef` renames both the binder and all internal `MonoTailCall oldName` references
to `info.freshName`, making each clone self-consistent.

### Step 7: Delete unused infrastructure

**File:** `compiler/src/Compiler/Monomorphize/Specialize.elm`

Remove these functions and types (all only referenced by each other and the old
`TOpt.Let` / `rewriteLocalCalls` code path):

| Symbol | Lines |
|--------|-------|
| `LocalFunInstance` (type alias) | 56-62 |
| `rewriteLocalCalls` | 2173-2259 |
| `rewriteMonoDef` | 2263-2269 |
| `rewriteDecider` | 2273-2286 |
| `rewriteChoice` | 2290-2296 |
| `findInstance` | 2302-2307 |
| `findInstanceWithKey` | 2311-2321 |
| `findInstanceByName` | 2328-2338 |
| `collectLocalInstantiations` | 2361-2366 |
| `deduplicateByMonoType` | 2370-2386 |
| `collectInstExpr` | 2396-2568 |
| `collectInstFromCallSite` | 2578-2591 |
| `collectInstDef` | 2601-2607 |
| `collectInstDecider` | 2617-2639 |
| `collectInstChoice` | 2649-2655 |

---

## Testing

1. **Frontend tests:** `cd compiler && npx elm-test-rs --fuzz 1`
2. **E2E tests:** `cmake --build build --target check`
3. Specifically watch for the `letWithFunctionCallingAnother` test case and any
   polymorphic-let tests.

## Invariants

- **MONO_005** (specialization correctness): Instance types now match call-site types by
  construction.
- **MONO_011** (mutual recursion scoping): Not affected — this change only applies to
  non-recursive `let` bindings.
