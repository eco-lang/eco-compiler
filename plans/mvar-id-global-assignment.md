# Plan: Global MVarId Assignment for Monomorphization

## Goal

Replace string-named type variables with globally unique sequential `Int` IDs (`MVarId`) throughout the monomorphization pipeline. This eliminates alpha-renaming, name-based hashing, and string-keyed substitutions.

## Current State

- `MVarEnv` uses bidirectional `nameToId`/`idToName` caches with DJB2 hash-based deterministic allocation (`State.elm:100-150`)
- `Substitution = Dict Name MonoType` keyed by string names (`State.elm`)
- `SchemeInfo` caches both original and pre-renamed type variants with `preRenameMap` (`State.elm:70-81`)
- `Specialize.elm` has `buildRenameMap`, `renameCanTypeVars`, `unifyCallSiteWithRenaming` for per-call alpha-renaming (`Specialize.elm:66-258`)
- `TypeSubst.elm` has `buildPreRenameMap`, `renameCanTypeVarsInternal`, `applyReverseRenaming`, `constraintFromName`, `findRootVar`, `normalizeMonoType` (`TypeSubst.elm:862-1001, 1227-1233`)
- `KernelAbi.elm` duplicates `constraintFromName` and uses `allocMVar` for MVar creation (`KernelAbi.elm:215-221, 235-369`)
- `Can.Type id` is already parameterized by `id` — `TVar id` carries the variable identity
- `TRecord` extension is `Maybe Name` (hardcoded) — will be parameterized to `Maybe id` (see Checkpoint 1)
- `SolverSnapshot.elm:263` uses `State.allocMVar "error"` for error sentinel MVarIds

## New Invariants

1. Single global supplier of `MVarId` for the entire monomorphization run
2. All type variables share one global contiguous range; no hashing, no reserved ranges
3. Type variables matched structurally (binder→uses) by walking types, not by name unification
4. Alpha-renaming in Monomorphize is removed; uniqueness provided by ID assignment
5. `number` constraints in a side table `Dict Int Mono.Constraint` (keyed by `Id.toComparable`), not name prefixes
6. Downstream consumers (GlobalOpt, MLIR) see same `MonoType` shape; only ID discipline changes
7. Path compression (union-find) retained for transitive MVar chains, rekeyed to `MVarId`

## Resolved Design Decisions

- **TRecord extension:** Parameterize to `Maybe id` in `Can.Type`. Blast radius is minimal — when `id = Name`, `Maybe id = Maybe Name` so all pre-monomorphization code (canonicalization, type inference, serialization) is unchanged. Only monomorphization code sees `Maybe MVarId`.
- **Path compression:** Keep `findRootVar`/`normalizeMonoType`, rekeyed from `Name` to `Int` (via `Id.toComparable`). Transitive chains can still form during unification.
- **Error sentinel:** Replace `allocMVar "error"` with `freshMVar CEcoValue` from the global supplier. No magic IDs. If downstream code needs to identify error sentinels, use an explicit flag or `Maybe MVarId` field.
- **Cycle nodes:** Build a combined SchemeEnv from all member definitions' annotations/inferred types. Cycle members are always top-level defs.
- **Substitution keys:** `Dict Int Mono.MonoType` keyed by `Id.toComparable mvarId`.
- **`collectCanTypeVars`:** Retire with the rename machinery. No ID-based variant unless a concrete non-rename use-site needs it.
- **Expression rewriting:** Full upfront rewrite of all `Expr`/`Meta` in `AssignMVarIds`. Clean boundary: past this point, no string-named tvars exist.

---

## Testable Checkpoints

The phases below form a logical implementation order, but they are NOT independently testable at every boundary. The type signature changes in Phase 3 (State) break all consumers (TypeSubst, Specialize, KernelAbi) until Phases 4-6 are also completed. The three points where all tests should pass are:

| Checkpoint | Phases | What to test | Why tests pass |
|-----------|--------|-------------|----------------|
| **Checkpoint 1** | Phases 1-2 | `elm-test-rs` + `cmake --build build --target full` | TRecord change is a type-level no-op when `id=Name`; AssignMVarIds is dead code (new module, not wired in) |
| **Checkpoint 2** | Phases 3-6 | `elm-test-rs` + `cmake --build build --target full` | Atomic rewrite: State + TypeSubst + Specialize + KernelAbi + Monomorphize entry all updated together. Semantically equivalent output. |
| **Checkpoint 3** | Phase 7 | `elm-test-rs` + `cmake --build build --target full` | Dead code removal and doc updates only |

Within Checkpoint 2, the recommended implementation order is: State types first (Phase 3, to establish the new interfaces), then TypeSubst (Phase 4, core substitution logic), then Specialize (Phase 5, call-site handling), then KernelAbi (Phase 6, kernel converters), then wire up AssignMVarIds at the Monomorphize entry point (Phase 3.5) last. The compiler will not compile between these steps.

---

## Implementation Steps

### Checkpoint 1: Type Definitions + Dead-Code AssignMVarIds Module

*All existing tests pass after this checkpoint. Commit here.*

#### Phase 1: Type definition changes (minimal blast radius)

##### Step 1.1: Parameterize TRecord extension in `Compiler/AST/Canonical.elm`

Change line 293:
```elm
-- Before:
| TRecord (Dict Name (FieldType id)) (Maybe Name)

-- After:
| TRecord (Dict Name (FieldType id)) (Maybe id)
```

**Blast radius analysis:** When `id = Name`, `Maybe id = Maybe Name` — identical type. All pre-monomorphization code operates on `Can.Type Name` so zero behavioral change. Specifically:
- **Serialization** (`Canonical.elm:569-574`): `typeEncoder : Type Name -> Encoder` — `ext : Maybe Name` unchanged
- **Deserialization** (`Canonical.elm:619-622`): `typeDecoder : Decoder (Type Name)` — `BD.maybe BD.string` unchanged
- **Canonicalize/Type.elm:199**: `Dict.insert ext () freeVars` — `ext : Name` unchanged
- **Canonicalize/Environment/Local.elm:391**: `Dict.insert ext extRegion freeVars` — unchanged
- **PostSolve.elm:1021**: `ext1 == ext2` equality — unchanged when both are `Name`
- **Reporting/Render/Type.elm:230,286**: `D.fromName ext` — unchanged
- **Type/Type.elm:597**: `Can.TRecord canFields (Just name)` — unchanged
- **All pass-through sites** (Utils/Type, KernelAbi, Specialize, TypeSubst): unchanged

Only code that operates on `Can.Type MVarId` (inside monomorphization, after AssignMVarIds) sees the new `Maybe MVarId` extension type.

##### Step 1.2: Add `Id` helpers to `Compiler/Data/Id.elm`

Add to the existing 34-line file:
- `first : Id a` returning `Id 0`
- `succ : Id a -> Id a` returning `Id (n + 1)`

##### Step 1.3: Add `firstMVarId` to `Compiler/AST/TypeIds.elm`

- `firstMVarId : MVarId` using `Id.first`

#### Phase 2: New AssignMVarIds pass (not wired in yet)

##### Step 2.1: Create `Compiler/Monomorphize/AssignMVarIds.elm`

Entry function:
```elm
assignIds : TOpt.GlobalGraph Name -> ( TOpt.GlobalGraph MVarId, MVarEnv )
```

Internal state:
```elm
type alias GlobalMVarState =
    { nextId : MVarId
    , constraints : Dict Int Mono.Constraint  -- keyed by Id.toComparable
    }

type alias SchemeEnv =
    Dict Name MVarId  -- per-scheme mapping from name to assigned ID
```

Key operations:
- `freshMVarId : Mono.Constraint -> GlobalMVarState -> ( MVarId, GlobalMVarState )` — allocate next sequential ID, record constraint in side table
- `rewriteScheme : GlobalMVarState -> Can.Type Name -> ( GlobalMVarState, Can.Type MVarId )` — collect free vars via `KernelAbi.freeTypeVariablesWithConstraints`, allocate IDs, then structurally rewrite
- `rewriteType : SchemeEnv -> Can.Type Name -> Can.Type MVarId` — structural replacement of `TVar name` → `TVar mvarId`, and `TRecord fields (Just extName)` → `TRecord fields' (Just extMvarId)` using the SchemeEnv

Since `GlobalGraph id` is already parameterized:
```elm
type GlobalGraph id = GlobalGraph (Data.Map.Dict ... Global (Node id)) (Dict Name Int) (Annotations id)
```
The output `GlobalGraph MVarId` is a natural specialization — no new type alias needed.

##### Step 2.2: Walk through GlobalGraph

- **Annotations**: `Dict Name (Can.Annotation Name)` → `Dict Name (Can.Annotation MVarId)`. Each `Forall freeVars type` gets its free vars from `FreeVars` dict, allocated as a scheme, then body rewritten.
- **Nodes**: Each variant gets rewritten:
  - `Define`/`TrackedDefine`/`PortIncoming`/`PortOutgoing`: rewrite `Meta id` (contains `meta.tipe`) and all subexpressions
  - `Ctor`/`Enum`/`Box`: rewrite `Can.Type id` directly
  - `Cycle`: build combined SchemeEnv from all member definitions' annotations, then rewrite all value bindings (`List (Name, Expr id)`) and function defs (`List (Def id)`)
  - `Link`/`Manager`/`Kernel`: no types to rewrite
- **Expressions**: Full upfront rewrite. Every `Expr id` constructor carries `Meta id` as last arg. Pattern-match all expression variants, rewrite `meta.tipe`, recurse into sub-expressions. SchemeEnv comes from enclosing definition's annotation.

##### Step 2.3: Handle record extension variables

During `rewriteType`, when encountering `TRecord fields (Just extName)`:
- Look up `extName` in the SchemeEnv to get its `MVarId`
- Produce `TRecord fields' (Just extMvarId)`
- The extension variable is treated exactly like any other `TVar` — allocated from the same global supplier

During `rewriteScheme`, record extension names are included in the free-vars collection (via `freeTypeVariablesWithConstraints` which already walks record types) and allocated IDs.

**Important:** This module is created but NOT wired into the Monomorphize entry point yet. It is dead code at this checkpoint, ensuring all tests pass unchanged.

---

### Checkpoint 2: Atomic Rewrite of Monomorphization Pipeline

*The compiler will not compile between the steps in this checkpoint. All steps must land together. All tests pass after the full checkpoint.*

*Recommended implementation order within this checkpoint: Phase 3 → Phase 4 → Phase 5 → Phase 6 → wire up AssignMVarIds (Step 3.5).*

#### Phase 3: Refactor MVarEnv and State

##### Step 3.1: Redefine `MVarEnv` in `Compiler/Monomorphize/State.elm`

Before (`State.elm:100-103`):
```elm
type alias MVarEnv =
    { nameToId : Dict Name MVarId
    , idToName : Dict Int Name
    }
```

After:
```elm
type alias MVarEnv =
    { nextId : MVarId
    , constraints : Dict Int Mono.Constraint  -- keyed by Id.toComparable
    }
```

New functions:
- `initMVarEnv : MVarId -> Dict Int Mono.Constraint -> MVarEnv`
- `freshMVar : Mono.Constraint -> MVarEnv -> ( MVarId, MVarEnv )` — allocate next sequential ID, record constraint
- `lookupConstraint : MVarId -> MVarEnv -> Maybe Mono.Constraint`

Remove:
- `emptyMVarEnv` (`State.elm:108-112`)
- `allocMVar` (`State.elm:132-150`)
- `lookupMVarName` (`State.elm:155-157`)
- `hashName` (`State.elm:118-125`)

##### Step 3.2: Update `SchemeInfo` in `State.elm`

Before (`State.elm:70-81`):
```elm
type alias SchemeInfo =
    { varNames : List Name
    , constraints : Dict Name Mono.Constraint
    , argTypes : List (Can.Type Name)
    , resultType : Can.Type Name
    , argCount : Int
    , renamedFuncType : Can.Type Name
    , renamedArgTypes : List (Can.Type Name)
    , renamedResultType : Can.Type Name
    , renamedVarNames : List Name
    , preRenameMap : DataMap.Dict String Name Name
    }
```

After:
```elm
type alias SchemeInfo =
    { varIds : List MVarId
    , constraints : Dict Int Mono.Constraint  -- keyed by Id.toComparable
    , argTypes : List (Can.Type MVarId)
    , resultType : Can.Type MVarId
    , argCount : Int
    , schemeType : Can.Type MVarId
    }
```

All rename-related fields dropped: `renamedFuncType`, `renamedArgTypes`, `renamedResultType`, `renamedVarNames`, `preRenameMap`.

##### Step 3.3: Update `SpecContext` in `State.elm`

At `State.elm:179-190`:
- Change `toptNodes` from `Data.Map.Dict ... TOpt.Global (TOpt.Node Name)` to `... (TOpt.Node MVarId)`
- Remove `renameEpoch : Int` field (line 188)
- `mvarEnv` field type changes to the new `MVarEnv`

##### Step 3.4: Update `Substitution` type

Before: `type alias Substitution = Dict Name Mono.MonoType`
After: `type alias Substitution = Dict Int Mono.MonoType` (keyed by `Id.toComparable mvarId`)

All Substitution operations use `Id.toComparable` for keys and wrap/unwrap as needed.

##### Step 3.5: Wire up in `Monomorphize.elm` entry point

*Do this last within the checkpoint, after Phases 4-6 are done.*

In `monomorphize`/`monomorphizeFromEntry` (`Monomorphize.elm:63-87`):
- Call `AssignMVarIds.assignIds globalTypedGraph` to get `( GlobalGraph MVarId, MVarEnv )`
- Pass `GlobalGraph MVarId` into state initialization instead of `GlobalGraph Name`
- Remove the pre-population loop at line 572 (`List.foldl ... State.allocMVar ...`)

##### Step 3.6: Update `SolverSnapshot.elm` error sentinel

At `SolverSnapshot.elm:263`:
- Replace `State.allocMVar "error" mvarEnv` with `State.freshMVar Mono.CEcoValue mvarEnv`
- The `MVarEnv` must be threaded through the solver snapshot context (it needs the global state to allocate)
- If `monoTypeOfVar` currently discards the updated env (`( errorMVarId, _ )`), change it to thread the env through or use a dedicated error flag instead of an MVar

#### Phase 4: Make TypeSubst ID-based

##### Step 4.1: Change function signatures in `TypeSubst.elm`

All public functions operate on `Can.Type MVarId` instead of `Can.Type Name`:
- `applySubst : MVarEnv -> Substitution -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )`
- `unify : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> ( Substitution, MVarEnv )`
- `unifyExtend : MVarEnv -> Can.Type MVarId -> Mono.MonoType -> Substitution -> ( Substitution, MVarEnv )`
- `unifyCallSiteDirect : MVarEnv -> List (Can.Type MVarId) -> Can.Type MVarId -> List Mono.MonoType -> Substitution -> ( Substitution, Mono.MonoType, MVarEnv )`
- `buildSchemeInfo` changes to accept `Can.Type MVarId` and return the simplified `SchemeInfo`

##### Step 4.2: Simplify `applySubst` TVar case

Before: looks up name in `Dict Name MonoType`, calls `constraintFromName`, calls `allocMVar`
After: looks up `Id.toComparable tvarId` in `Dict Int MonoType`, calls `lookupConstraint tvarId env`

For unresolved `CNumber` vars: default to `MInt` (existing behavior).
For unresolved `CEcoValue` vars: emit `MVar tvarId CEcoValue` directly (no allocation needed — ID already globally unique).

##### Step 4.3: Simplify `applySubst` TRecord case

Before (`TypeSubst.elm:729-758`): looks up `extName` in `Dict Name MonoType` substitution
After: looks up `Id.toComparable extMvarId` in `Dict Int MonoType` substitution — the extension is now `Maybe MVarId` thanks to the `TRecord` parameterization

The rest of the TRecord handling (field conversion, base field merging) works the same way, just with `MVarId`-keyed lookups.

##### Step 4.4: Rekey path compression to `MVarId`

Keep `findRootVar` and `normalizeMonoType` but change their key types:
- `findRootVar : MVarEnv -> Int -> Substitution -> ( Int, Substitution, MVarEnv )` — follows `MVar` chains using `Id.toComparable` keys
- `normalizeMonoType : MVarEnv -> Substitution -> Mono.MonoType -> ( Mono.MonoType, Substitution, MVarEnv )` — resolves and compresses MVar references

Remove `Name`-specific logic from these functions (no `constraintFromName` calls, use `lookupConstraint` instead).

##### Step 4.5: Simplify `unifyHelp` TVar case

Before: string key lookup → `findRootVar` → `insertBinding` with name key
After: `Id.toComparable` key lookup → `findRootVar` (rekeyed) → `insertBinding` with Int key

##### Step 4.6: Remove name-based helpers

Delete from `TypeSubst.elm`:
- `constraintFromName` (lines 1227-1233)
- `buildPreRenameMap` (lines 909-929)
- `renameCanTypeVarsInternal` (lines 960-1001)
- `applyReverseRenaming` (lines 936-954)
- `collectCanTypeVars` (lines ~600-615) — only used by rename/scheme machinery
- All rename-related code paths in `buildSchemeInfo` (lines 862-903)

#### Phase 5: Simplify Specialize.elm

##### Step 5.1: Remove renaming machinery

Delete:
- `buildRenameMap` (lines 66-81)
- `renameCanTypeVars` (lines 84-125)
- `unifyCallSiteWithRenaming` (lines 192-258)

##### Step 5.2: Replace with direct unification

Create `unifyCallSite`:
```elm
unifyCallSite :
    MVarEnv
    -> Can.Type MVarId          -- function's scheme type
    -> List Mono.MonoType        -- call-site argument MonoTypes
    -> Can.Type MVarId           -- call-site result type
    -> Substitution              -- current substitution
    -> SchemeInfo
    -> { callSubst : Substitution
       , funcMonoType : Mono.MonoType
       , mvarEnv : MVarEnv
       }
```

- Directly unify scheme arg types with call-site mono types using `TypeSubst.unifyExtend`
- No renaming, no epoch, no reverse renaming
- Returns single substitution (no `callSubstAligned` vs `callSubst` distinction needed)

Alternatively, reuse/adapt `TypeSubst.unifyCallSiteDirect` (lines 1031-1056) which already does single-pass call-site unification — just rekey it to `MVarId`.

##### Step 5.3: Simplify `getOrBuildSchemeInfo`

- Receives `Can.Type MVarId` instead of `Can.Type Name`
- No longer pre-populates MVarEnv with renamed names (no `List.foldl ... allocMVar` loops at lines 154, 174)
- No longer calls `TypeSubst.buildSchemeInfo` with rename prefix
- Simply: flatten TLambda chain to get arg types + result type, collect var IDs, look up their constraints from `MVarEnv.constraints`

##### Step 5.4: Update all call-site handling

Every `TOpt.Call` / `TOpt.VarGlobal` / `TOpt.VarKernel` handler (lines ~1382-1588):
- Remove `epoch = state.ctx.renameEpoch` and `{ c | renameEpoch = epoch + 1 }` patterns
- Use `unifyCallSite` instead of `unifyCallSiteWithRenaming`
- Remove `renamedFuncType` usage — pass `funcCanType : Can.Type MVarId` directly to kernel ABI derivation

#### Phase 6: Update KernelAbi.elm

##### Step 6.1: Change converter signatures

- `canTypeToMonoType_preserveVars : MVarEnv -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )`
- `canTypeToMonoType_numberBoxed : MVarEnv -> Can.Type MVarId -> ( Mono.MonoType, MVarEnv )`
- `deriveKernelAbiMode` receives `Can.Type MVarId` and uses `MVarEnv.constraints` instead of `constraintFromName`

##### Step 6.2: Replace `allocMVar` calls with direct ID reuse

In `canTypeToMonoType_preserveVars` (line 241) and `canTypeToMonoType_numberBoxed` (line 313):
- `Can.TVar tvarId` case: directly emit `Mono.MVar tvarId constraint` using `State.lookupConstraint tvarId env`
- No `State.allocMVar name env` calls — the ID already exists from AssignMVarIds

##### Step 6.3: Update free-var helpers

Keep `freeTypeVariablesWithConstraints : Can.Type Name -> List (Name, Mono.Constraint)` for use in `AssignMVarIds` (during initial ID assignment, before the rewrite).

For post-rewrite usage inside monomorphization, either:
- Add `freeVarIds : Can.Type MVarId -> List MVarId` (simple walk collecting `TVar` IDs), or
- Inline equivalent logic where needed (it's trivial with IDs)

Delete `constraintFromName` from KernelAbi (lines 215-221).

---

### Checkpoint 3: Cleanup and Documentation

*All existing tests pass after this checkpoint. Commit here.*

#### Phase 7: Remove dead code and update docs

##### Step 7.1: Remove all obsolete name-based code

Verify these are now unreferenced, then delete:
- **State.elm:** `emptyMVarEnv`, `allocMVar`, `lookupMVarName`, `hashName` (should already be removed in Checkpoint 2, but verify no stragglers)
- **TypeSubst.elm:** `constraintFromName`, `buildPreRenameMap`, `renameCanTypeVarsInternal`, `applyReverseRenaming`, `collectCanTypeVars` (should already be removed in Checkpoint 2)
- **Specialize.elm:** `buildRenameMap`, `renameCanTypeVars`, `unifyCallSiteWithRenaming` (should already be removed in Checkpoint 2)
- **KernelAbi.elm:** `constraintFromName` (should already be removed in Checkpoint 2)
- Any remaining dead imports, unused helper functions, or orphaned type aliases across the Monomorphize module tree

##### Step 7.2: Update theory docs

- `design_docs/theory/pass_monomorphization_theory.md`:
  - Document global `MVarId` assignment pass and its position in the pipeline (after TypedOpt merge, before specialization)
  - Remove references to string-based substitutions and alpha-renaming complexity
  - Document new invariants: all `Can.Type` seen by Monomorphize are `Can.Type MVarId`; MVarIds are globally unique sequential Ints; constraints in `MVarEnv.constraints` side table
- `design_docs/theory/solver-state-optimization.md`:
  - Note alignment with MonoDirect's approach (both avoid string-based substitution)

---

## File Change Summary

| File | Checkpoint | Change Type | Description |
|------|-----------|------------|-------------|
| `AST/Canonical.elm:293` | 1 | Modify | `TRecord ... (Maybe Name)` → `TRecord ... (Maybe id)` |
| `Data/Id.elm` | 1 | Add | `first`, `succ` helpers |
| `AST/TypeIds.elm` | 1 | Add | `firstMVarId` |
| `Monomorphize/AssignMVarIds.elm` | 1 | **New file** | `assignIds` pass (dead code until Checkpoint 2) |
| `Monomorphize/State.elm` | 2 | Major rewrite | New `MVarEnv`, new `SchemeInfo`, remove name-based machinery |
| `Monomorphize/Monomorphize.elm` | 2 | Modify | Wire AssignMVarIds at entry, remove pre-population |
| `Monomorphize/TypeSubst.elm` | 2 | Major rewrite | ID-based substitutions, remove rename helpers, rekey path compression |
| `Monomorphize/Specialize.elm` | 2 | Major rewrite | Direct unification, remove rename machinery |
| `Monomorphize/KernelAbi.elm` | 2 | Moderate | ID-based converters, remove `constraintFromName` |
| `Type/SolverSnapshot.elm:263` | 2 | Modify | Replace `allocMVar "error"` with `freshMVar` |
| Theory docs | 3 | Update | Document new invariants and design |

---

## Risk Assessment

- **Highest risk:** Checkpoint 2 (Phases 3-6) — atomic rewrite of the entire monomorphization type pipeline. Most code paths, most potential for subtle type-resolution bugs. Cannot be tested incrementally.
- **Medium risk:** Phase 2 within Checkpoint 1 (AssignMVarIds) — must correctly scope SchemeEnvs per definition and handle all expression variants. Can be tested in isolation by calling it from a test harness, but won't be integration-tested until Checkpoint 2.
- **Low risk:** Phase 1 within Checkpoint 1 (TRecord parameterization) — type-level change, `Maybe id = Maybe Name` when `id = Name`.
- **Lowest risk:** Checkpoint 3 — dead code removal and documentation only.

## Testing Strategy

- **Checkpoint 1:** `cd compiler && npx elm-test-rs --fuzz 1` + `cmake --build build --target full`. Should be a no-op — all tests pass with zero behavioral change.
- **Checkpoint 2:** `cd compiler && npx elm-test-rs --fuzz 1` + `cmake --build build --target full`. This is the critical gate. If failures occur, compare MonoGraph output for specific test programs before/after to isolate divergence.
- **Checkpoint 3:** `cd compiler && npx elm-test-rs --fuzz 1` + `cmake --build build --target full`. Should be trivially passing — only dead code removal.
