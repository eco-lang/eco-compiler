# Plan: Reduce `_Utils_update` Overhead via MonoState Split

## Problem

Profiling shows ~50% of monomorphization time is spent in V8 GC, driven heavily by `_Utils_update` allocations. `MonoState` has **16 fields**. Every Elm record update `{ state | field = x }` compiles to `_Utils_update`, which allocates a new JS object and copies all 16 key-value pairs — even when changing just 1 field.

There are ~30 record update sites across `processWorklist` (3 per iteration) and `specializeExpr` (26 sites in Specialize.elm). Since `specializeExpr` recurses into every AST node, the total cost is:

    (AST nodes) × (avg updates per node) × (16 field copies per update)

## Goal

Split `MonoState` into two records grouped by mutation pattern, cutting field copies per `_Utils_update` roughly in half.

## Prerequisites

- Run `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` after each step
- Run `cmake --build build --target check` after all steps

---

## Step 0: Quick Win — Merge Adjacent Updates in `processWorklist`

### File: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

Currently `processWorklist` does two sequential updates:
```elm
state1 = { state | worklist = rest }           -- copies 16 fields
-- ... reads state1.inProgress, state1.registry (unchanged from state) ...
state2 = { state1 | inProgress = ..., currentGlobal = ..., varEnv = ... }  -- copies 16 fields again
```

Merge into one update on the happy path:
```elm
state2 = { state | worklist = rest, inProgress = ..., currentGlobal = ..., varEnv = ... }
```

For the skip/missing branches, use `{ state | worklist = rest }` directly in the recursive call.

**This eliminates one 16-field copy per worklist iteration on the main path.**

### Verification
- Elm tests pass, E2E tests pass, no behavioral change.

---

## Step 1: Define `SpecAccum` and `SpecContext` Types

### File: `compiler/src/Compiler/Monomorphize/State.elm`

Split the current `MonoState` into two records:

```elm
type alias SpecAccum =
    { worklist : List WorkItem
    , nodes : Dict Int Mono.MonoNode
    , inProgress : BitSet
    , scheduled : BitSet
    , registry : Mono.SpecializationRegistry
    , callEdges : Dict Int (List Int)
    , specHasEffects : BitSet
    , specValueUsed : BitSet
    }

type alias SpecContext =
    { currentModule : IO.Canonical
    , toptNodes : DataMap.Dict (List String) TOpt.Global TOpt.Node
    , currentGlobal : Maybe Mono.Global
    , globalTypeEnv : TypeEnv.GlobalTypeEnv
    , varEnv : VarEnv
    , localMulti : List LocalMultiState
    , lambdaCounter : Int
    , renameEpoch : Int
    }

type alias MonoState =
    { accum : SpecAccum
    , ctx : SpecContext
    }
```

### Rationale for the split

- **SpecAccum** fields change on `enqueueSpec` / `processWorklist` completion (worklist push, registry insert, node insert, bitset updates). These are the "global accumulator" fields.
- **SpecContext** fields change on scope entry/exit during tree traversal (varEnv push/pop, localMulti push/pop, renameEpoch bump, currentGlobal set). These are the "traversal context" fields.
- Most update sites touch **only one group**: `enqueueSpec` only touches `accum`; `{ state | varEnv = ... }` only touches `ctx`. With the split, each such update copies 8 fields instead of 16.

### File: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

Update `initState` to construct the nested record.

### Verification
- Project compiles (will have many errors to fix in Steps 2-3).

---

## Step 2: Update `enqueueSpec` and Registry Operations

### File: `compiler/src/Compiler/Monomorphize/Specialize.elm`

Change `enqueueSpec` signature from threading `MonoState` to threading `SpecAccum`:
```elm
enqueueSpec : Global -> MonoType -> Maybe LambdaId -> SpecAccum -> ( SpecId, SpecAccum )
```

At call sites in `specializeExpr`, extract and re-insert:
```elm
let
    ( specId, newAccum ) =
        enqueueSpec global monoType maybeLambda state.accum
in
( specId, { state | accum = newAccum } )
```

The `{ state | accum = newAccum }` update now copies only 2 fields (the `MonoState` wrapper) instead of 16. The internal `SpecAccum` update in `enqueueSpec` copies 8 fields instead of 16.

**Alternative (avoids even the 2-field wrapper copy):** Thread `( SpecAccum, SpecContext )` as a tuple instead of a wrapper record. Then updates are just `( newAccum, ctx )` — a tuple allocation (3 words) instead of a record copy.

### Verification
- Fix all compile errors from changed field access patterns.

---

## Step 3: Update `specializeExpr` Context Updates

### File: `compiler/src/Compiler/Monomorphize/Specialize.elm`

All ~26 context-only updates become:
```elm
-- Before (copies 16 fields):
{ state | varEnv = newVarEnv }

-- After (copies 8 fields):
{ state | ctx = { state.ctx | varEnv = newVarEnv } }
```

Or with the tuple approach:
```elm
( accum, { ctx | varEnv = newVarEnv } )
```

### Verification
- Elm tests pass.

---

## Step 4: Update `processWorklist`

### File: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

Update `processWorklist` to work with the split state. The final state assembly at each branch updates `accum` for node insertion and `ctx` for currentGlobal/varEnv reset:

```elm
let
    newAccum =
        { accum | nodes = Dict.insert specId monoNode stateAfter.accum.nodes, ... }
    newCtx =
        { stateAfter.ctx | currentGlobal = Nothing }
in
processWorklist { accum = newAccum, ctx = newCtx }
```

### Verification
- Elm tests and E2E tests pass.

---

## Step 5: Update Remaining Callers

### Files to update (compile-error driven):
- `compiler/src/Compiler/Monomorphize/Monomorphize.elm` — `runSpecialization`, `assembleRawGraph`, `monomorphizeFromEntry`
- `compiler/src/Compiler/Monomorphize/Prune.elm` — if it accesses `MonoState` fields
- Any other file importing `State.MonoState`

Each is mechanical: change `state.field` to `state.accum.field` or `state.ctx.field`.

### Verification
- Full `elm-test-rs` pass.
- `cmake --build build --target check` pass.

---

## Expected Impact

| Metric | Before | After |
|---|---|---|
| Fields copied per `enqueueSpec` update | 16 | 8 |
| Fields copied per `varEnv` update | 16 | 8 |
| Fields copied per `processWorklist` iteration | 48 (3×16) | 24–28 |
| Transient object size | 16 fields | 8 fields |
| GC pressure from state threading | ~50% of runtime | Estimated ~30-35% |

The reduction is proportional because `_Utils_update` allocation is linear in field count, and GC work is proportional to allocation volume.

## Risks

- **Mechanical but large refactor**: ~40-50 sites need field access path changes. All compile-error driven (no silent breakage).
- **Nested record update ergonomics**: `{ state | ctx = { state.ctx | varEnv = x } }` is more verbose. The tuple approach `( accum, ctx )` avoids this but changes the threading pattern more significantly.
- **No algorithmic change**: This is purely a constant-factor optimization on allocation. It won't help if the worklist itself is doing redundant work (that's a separate concern).
