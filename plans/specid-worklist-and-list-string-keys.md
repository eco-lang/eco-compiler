# Plan: SpecId-Based Worklist + List String Registry Keys

## Problem

Monomorphization of the self-hosting compiler (231 modules) creates ~30K+ unique specializations but processes ~110K+ worklist iterations — ~70% are redundant re-encounters of already-processed specs. Each iteration recomputes a `String` key via `toComparableSpecKey` (walking the full MonoType tree, concatenating into a single large string) and performs a Dict lookup. Combined with GC pressure from large throwaway key strings, the worklist loop stalls at scale (can't finish in 10+ minutes).

## Goal

1. Eliminate redundant worklist processing via `SpecId`-based deduplication (`scheduled` BitSet).
2. Reduce allocation pressure by switching `SpecializationRegistry.mapping` from `Dict String SpecId` to `Dict (List String) SpecId`, avoiding monolithic string concatenation.

## Prerequisites

- Read `design_docs/invariants.csv` (MONO_005, MONO_017, MONO_022)
- Run `cd compiler && npx elm-test-rs --project build-xhr --fuzz 1` after each step
- Bootstrap through Stage 4 after all changes to verify fixed-point

## Design Decisions (Resolved)

- **Cycle specialization calls** (`specializeFunctionCycle` ~line 515, `specializeFunc` ~line 558): These use `getOrCreateSpecId` for registry-only lookups without worklist pushes. **Leave as-is.**
- **Key representation**: Use `List String` — avoids string concatenation entirely. Element-wise list comparison short-circuits on first differing element.
- **`enqueueSpec` location**: Lives in `Specialize.elm` (where all 8 call sites are).
- **`nodes` membership check**: **Remove** from `processWorklist`. Rely solely on `scheduled` BitSet — if a specId was scheduled, it was either already processed or is in-progress. This saves one `DMap.member` per iteration.

---

## Step 1: Add `scheduled : BitSet` to `MonoState`

### File: `compiler/src/Compiler/Monomorphize/State.elm`

1. Add `scheduled : BitSet` field to `MonoState` record (after `inProgress`).
2. Initialize to `BitSet.empty` in `initState`.
3. Import `Compiler.Data.BitSet as BitSet` if not already imported.

### Verification
- Compiles cleanly, no behavioral change yet.

---

## Step 2: Change `WorkItem` to carry only `SpecId`

### File: `compiler/src/Compiler/Monomorphize/State.elm`

1. Change `WorkItem` from:
   ```elm
   type WorkItem
       = SpecializeGlobal Mono.Global Mono.MonoType (Maybe Mono.LambdaId)
   ```
   to:
   ```elm
   type WorkItem
       = SpecializeGlobal Mono.SpecId
   ```

This will cause compile errors in `Monomorphize.elm` and `Specialize.elm` — those are fixed in Steps 3-5.

---

## Step 3: Add `enqueueSpec` helper in `Specialize.elm`

### File: `compiler/src/Compiler/Monomorphize/Specialize.elm`

Add a helper near the top (after internal type definitions):

```elm
enqueueSpec :
    Mono.Global
    -> Mono.MonoType
    -> Maybe Mono.LambdaId
    -> MonoState
    -> ( Mono.SpecId, MonoState )
enqueueSpec global monoType maybeLambda state =
    let
        ( specId, newRegistry ) =
            Registry.getOrCreateSpecId global monoType maybeLambda state.registry
    in
    if BitSet.member specId state.scheduled then
        ( specId, { state | registry = newRegistry } )
    else
        ( specId
        , { state
            | registry = newRegistry
            , scheduled = BitSet.insertGrowing specId state.scheduled
            , worklist = SpecializeGlobal specId :: state.worklist
          }
        )
```

Import `BitSet` if needed.

### Verification
- Compiles (function not called yet).

---

## Step 4: Update all enqueue sites in `Specialize.elm`

### File: `compiler/src/Compiler/Monomorphize/Specialize.elm`

There are **8 call sites** that call `getOrCreateSpecId` + push `SpecializeGlobal` onto the worklist. Each must be replaced with `enqueueSpec`.

**Sites (by line reference and expression type):**

| # | Location | Expression Type | Notes |
|---|----------|----------------|-------|
| 1 | `VarGlobal` (standalone, ~line 765) | `specializeExpr` | Standard pattern |
| 2 | `VarEnum` (~line 797) | `specializeExpr` | Standard pattern |
| 3 | `VarBox` (~line 816) | `specializeExpr` | Standard pattern |
| 4 | `VarCycle` (~line 835) | `specializeExpr` | Uses `Mono.Global canonical name` directly |
| 5 | `Call > VarGlobal` (~line 919) | `specializeExpr` nested call | Uses `funcMonoType` not `monoType` |
| 6 | `Accessor` (standalone, ~line 1370) | `specializeExpr` | Uses `accessorGlobal` |
| 7 | `resolveProcessedArg` PendingAccessor record (~line 1754) | arg resolution | Uses `accessorGlobal` + `accessorMonoType` |
| 8 | `resolveProcessedArg` PendingAccessor tuple (~line 1786) | arg resolution | Similar to #7 |

**For each site, replace:**
```elm
( specId, newRegistry ) =
    Registry.getOrCreateSpecId monoGlobal monoType Nothing state.registry

newState =
    { state
        | registry = newRegistry
        , worklist = SpecializeGlobal monoGlobal monoType Nothing :: state.worklist
    }
```

**With:**
```elm
( specId, newState ) =
    enqueueSpec monoGlobal monoType Nothing state
```

**Two call sites that do NOT enqueue** (registry-only, in cycle specialization) — **leave as-is**:
- `specializeFunctionCycle` (~line 515)
- `specializeFunc` (~line 558)

### Verification
- All `SpecializeGlobal` constructor usages in `Specialize.elm` now use `SpecId` only.
- No direct worklist pushes remain outside `enqueueSpec`.

---

## Step 5: Rewrite `processWorklist` and seeding in `Monomorphize.elm`

### File: `compiler/src/Compiler/Monomorphize/Monomorphize.elm`

### 5a. Seed the worklist with `SpecId`

In `monomorphizeFromEntry`, replace the worklist seeding:

```elm
-- Old:
stateWithMain =
    { initialState
        | worklist = [ SpecializeGlobal (toptGlobalToMono mainGlobal) mainMonoType Nothing ]
    }
```

With:
```elm
-- New:
( mainSpecIdVal, registryWithMain ) =
    Registry.getOrCreateSpecId (toptGlobalToMono mainGlobal) mainMonoType Nothing initialState.registry

stateWithMain =
    { initialState
        | registry = registryWithMain
        , worklist = [ SpecializeGlobal mainSpecIdVal ]
        , scheduled = BitSet.insertGrowing mainSpecIdVal initialState.scheduled
    }
```

### 5b. Simplify `mainSpecId` lookup

Replace the `mainKey : String` / `Dict.get mainKey` logic with the already-known `mainSpecIdVal`:
```elm
mainInfo = Just (Mono.StaticMain mainSpecIdVal)
```

Change `valueUsedWithMain` to use `mainSpecIdVal` directly (no `Maybe.map`/`case` needed):
```elm
valueUsedWithMain =
    BitSet.insertGrowing mainSpecIdVal finalState.specValueUsed
```

### 5c. Rewrite `processWorklist`

Change the pattern match and remove the `nodes` membership check (rely on `scheduled` BitSet):

```elm
(SpecializeGlobal specId) :: rest ->
    let
        state1 = { state | worklist = rest }
    in
    if BitSet.member specId state1.inProgress then
        -- Skip to avoid infinite recursion on recursive specs
        processWorklist state1
    else
        case Registry.lookupSpecKey specId state1.registry of
            Nothing ->
                -- Should not happen if registry/worklist invariants hold
                processWorklist state1

            Just ( global, monoType, _maybeLambda ) ->
                let
                    state2 =
                        { state1
                            | inProgress = BitSet.insertGrowing specId state1.inProgress
                            , currentGlobal = Just global
                            , varEnv = State.emptyVarEnv
                        }
                in
                case global of
                    Mono.Accessor fieldName ->
                        -- ... existing accessor logic unchanged ...

                    Mono.Global _ name ->
                        -- ... existing global logic unchanged ...
```

Key changes:
- No `getOrCreateSpecId` call — specId comes from the worklist directly.
- No `DMap.member identity specId state1.nodes` check — `scheduled` guarantees each specId is dequeued at most once.
- `global` and `monoType` recovered via `Registry.lookupSpecKey`.
- The `Accessor` and `Global` branch bodies are identical to the original.

### Verification
- `elm-test-rs` passes.
- Bootstrap through Stage 4 reaches fixed-point.

---

## Step 6: Switch `SpecializationRegistry.mapping` to `Dict (List String) SpecId`

### File: `compiler/src/Compiler/AST/Monomorphized.elm`

1. Change `SpecializationRegistry`:
   ```elm
   type alias SpecializationRegistry =
       { nextId : Int
       , mapping : Dict (List String) SpecId
       , reverseMapping : Array (Maybe ( Global, MonoType, Maybe LambdaId ))
       }
   ```

2. Change `toComparableSpecKey` signature and implementation:
   ```elm
   toComparableSpecKey : SpecKey -> List String
   toComparableSpecKey (SpecKey global monoType maybeLambda) =
       toComparableGlobal global
           ++ [ "\u{0001}" ]
           ++ toComparableMonoType monoType
           ++ [ "\u{0001}" ]
           ++ (case maybeLambda of
                   Nothing -> [ "N" ]
                   Just lambdaId -> "L" :: toComparableLambdaId lambdaId
              )
   ```

### Files affected by type change propagation:

| File | Location | Change |
|------|----------|--------|
| `Registry.elm` | `getOrCreateSpecId` | `key` type inferred as `List String` — no code change needed |
| `Monomorphize.elm` | `newMapping` rebuild (~line 201) | `key` type inferred — no code change needed |
| `Prune.elm` | `mapping1` rebuild (~line 143) | Update type annotation from `Dict String` to `Dict (List String)` |

### Verification
- `elm-test-rs` passes.
- Bootstrap through Stage 4 reaches fixed-point.

---

## Step 7: Clean up and verify

1. Remove any debugging instrumentation from `eco-boot-2.js` (the edited copy is not in source control, but verify no stray changes).
2. Full bootstrap (Stages 1-4) to verify fixed-point.
3. Run `cmake --build build --target check` for E2E tests.

---

## Files Modified (Summary)

| File | Changes |
|------|---------|
| `compiler/src/Compiler/Monomorphize/State.elm` | Add `scheduled : BitSet` to `MonoState`, change `WorkItem` to `SpecializeGlobal SpecId` |
| `compiler/src/Compiler/Monomorphize/Specialize.elm` | Add `enqueueSpec` helper, update 8 call sites |
| `compiler/src/Compiler/Monomorphize/Monomorphize.elm` | Rewrite `processWorklist` (remove `nodes` check, use `scheduled`), rewrite worklist seeding, remove `mainKey` string lookup |
| `compiler/src/Compiler/AST/Monomorphized.elm` | Change `SpecializationRegistry.mapping` type to `Dict (List String) SpecId`, change `toComparableSpecKey` return type to `List String` |
| `compiler/src/Compiler/Monomorphize/Prune.elm` | Update `mapping1` type annotation |

## Invariants Preserved

- **MONO_005** (registry completeness): Unchanged — registry still maps keys to specIds.
- **MONO_017** (registry type matches node type): Unchanged — `reverseMapping` + `updateRegistryType` untouched.
- **MONO_022** (reachability from main): Unchanged — uses specId values not key types.

## Expected Impact

- **~70% fewer worklist iterations** (each SpecId processed exactly once).
- **No `toComparableSpecKey` calls in the hot loop** (moved to `getOrCreateSpecId` only, called once per unique spec).
- **Reduced GC pressure** from `List String` keys (no string concatenation) vs monolithic `String` building.
