# Plan: Phantom-Typed IDs, MVar Integer IDs, and Constraint Side-Tables

## Status: DRAFT — awaiting approval

## Goal

Three coordinated changes:
1. **MVar uses integer IDs** — `MVar MVarId Constraint` instead of `MVar Name Constraint`
2. **IDs are opaque, sequential, supply-only** — no `fromInt`, no semantic ranges
3. **Constraints come from side-tables, not string names** — `Dict Int Constraint` replaces `constraintFromName`

---

## Decisions (resolved)

- **FreeVars**: Full restructure — change to record with `displayNames` and `constraints` fields.
- **TVarConstraints key**: Must be `Dict Int Constraint` (keyed by `Id.toComparable`), not `Dict Name Constraint`.
- **Substitution key**: Keep keyed by `Name` — too large a change to migrate to Int in this refactoring.
- **MonoDirect**: Update in this PR (not deferred).
- **Can.Type parameterization**: Still desired. Big but mechanical. Included as Phase 6.
- **Error MVars**: Use `Result String MVarId` — `Err "error"` for error cases, no sentinel IDs.
- **Artifacts**: Confirmed unaffected — `.ecot` stores `Can.Type`, not `MonoType`.

---

## Current State (from codebase exploration)

- **No `Compiler/Data/Id.elm` exists.** Only `Compiler/Data/Index.elm` (ZeroBased wrapper).
- **`Can.FreeVars = Dict Name ()`** — just a set of tvar name strings.
- **`Can.Annotation = Forall FreeVars Type`** — FreeVars is name-only.
- **TypedOptimized has no separate `Type`** — it uses `Can.Type` directly via `Meta.tipe`.
- **`MVar Name Constraint`** — MVars carry string names today.
- **`constraintFromName`** defined in both `TypeSubst.elm:1134` and `KernelAbi.elm:214`, both delegate to `Name.isNumberType` (string prefix check).
- **`hasCEcoTVar`** in `Specialize.elm:386` collects tvar names and checks `constraintFromName`.
- **MVar created at 7 sites**: TypeSubst (4), KernelAbi (2), SolverSnapshot (1).
- **MVar pattern-matched at ~25 sites** across 10 files.
- **No existing phantom types, Supply, or TVarInterning.**

---

## Implementation Plan

### Phase 1: Core Id Infrastructure

**Step 1.1 — Create `Compiler/Data/Id.elm`**
- New file: `compiler/src/Compiler/Data/Id.elm`
- Expose: `Id`, `Supply`, `newSupply`, `next`, `toComparable`
- Do NOT expose `fromInt` or the `Id` constructor
- `Id a = Id Int` (phantom-typed), `Supply a = Supply Int`
- `newSupply = Supply 0`, `next (Supply n) = (Id n, Supply (n+1))`
- `toComparable (Id n) = n`

**Step 1.2 — Create `Compiler/AST/TypeIds.elm`**
- New file with phantom markers and aliases:
  - `type TVarPh = TVarPh`
  - `type alias TVarId = Id TVarPh`
  - `type MVarPh = MVarPh`
  - `type alias MVarId = Id MVarPh`

### Phase 2: MVar Name → MVarId (Monomorphized AST)

**Step 2.1 — Change `MVar` in `Compiler/AST/Monomorphized.elm`**
- `MVar Name Constraint` → `MVar MVarId Constraint`
- Import `Compiler.AST.TypeIds exposing (MVarId)` and `Compiler.Data.Id as Id`

**Step 2.2 — Update `toComparableMonoType`** (Monomorphized.elm:884)
- Change `"V" ++ name` → `"V" ++ String.fromInt (Id.toComparable mvarId)`

**Step 2.3 — Update `monoTypeToDebugString`** (Monomorphized.elm:695)
- Change `"MVar " ++ name` → `"MVar#" ++ String.fromInt (Id.toComparable mvarId)`

**Step 2.4 — Update pattern matches in Monomorphized.elm**
- `containsAnyMVar`, `containsCEcoMVar`, `forceCNumberToInt` — these ignore the id field, just update patterns from `MVar name _` / `MVar _ constraint` to `MVar _ constraint` (most already use wildcard for the id)

**Step 2.5 — Update MVar pattern matches in other files** (~20 sites across 9 files)
- `TypeSubst.elm` (8 patterns) — most significant, see Phase 3
- `MLIR/Types.elm` (2), `MLIR/Context.elm` (2), `MLIR/TypeTable.elm` (1) — all use wildcard for name, mechanical update
- `GlobalOpt/Staging/GraphBuilder.elm` (1) — debug name, use `Id.toComparable`
- `MonoDirect/Specialize.elm` (1) — update pattern and any MVar creation
- `SolverSnapshot.elm` (2) — error MVar changes to `Result String MVarId` (see Step 3.4)

### Phase 3: Supply Threading and Substitution Key Migration

**Step 3.1 — Thread `Supply MVarPh` through monomorphization state**
- Add `mvarSupply : Id.Supply MVarPh` to the monomorphization state record (in `State.elm` or equivalent)
- Initialize with `Id.newSupply` at monomorphization entry point

**Step 3.2 — Update MVar creation sites to allocate from supply**
- `TypeSubst.elm` (4 creation sites: lines 128, 148, 628, 1041):
  - Each allocates a fresh MVarId from the threaded supply
  - Union-find resolution switches to `Int` keys (see Step 3.3)
- `KernelAbi.elm` (2 creation sites: lines 238, 283):
  - Thread supply through kernel ABI conversion functions
- `MonoDirect/Specialize.elm`:
  - Thread supply through MonoDirect's state (it has its own state record)

**Step 3.3 — Keep `Substitution` keyed by Name**
- `type alias Substitution = Dict Name Mono.MonoType` — **unchanged**
- Migrating to Int keys is too large a change for this refactoring
- MVar creation sites allocate a fresh `MVarId` from the supply, but the substitution continues to map tvar **names** to MonoTypes
- **`resolveMonoVars` union-find**: Currently uses MVar name as key. This stays as-is — the union-find maps `Name → MonoType`, and when it encounters an `MVar mvarId _`, it uses the **name that was used to insert it** as the key, not the MVarId
- **Implication**: Each MVar creation site needs both a fresh MVarId (for the MVar constructor) AND the original tvar name (for the substitution key). Thread both through.

**Step 3.4 — Error MVars via `Result String MVarId`**
- In `SolverSnapshot.elm:259`, change `MVar "error" CEcoValue` pattern:
  - Functions that can fail to produce an MVarId return `Result String MVarId`
  - Error case: `Err "error"` (or more descriptive message)
  - Callers pattern-match and handle the error path (propagate or default)
  - This avoids sentinel IDs and keeps the supply-only invariant

### Phase 4: Constraint Side-Table (eliminate `constraintFromName`)

**Step 4.1 — Define `TVarConstraints`**
- `type alias TVarConstraints = Dict Int Mono.Constraint`
- Keyed by `Id.toComparable tvarId` (Int, not Name)
- Lives in a new `Compiler/AST/TypedOptimized/TVarInterning.elm` module

**Step 4.2 — Build the side-table and name-to-id mapping at monomorphization entry**
- At `Builder/Generate.elm:725` (before calling `monomorphize`):
  - Walk the TOpt GlobalGraph's type annotations (`Can.Type` in each node's `Meta.tipe`)
  - For each distinct `Can.TVar name`:
    - Allocate a fresh `TVarId` from a single global `Supply TVarPh`
    - Derive constraint via `constraintFromName name` **once** (transitional seeding)
    - Store `Id.toComparable tvarId → constraint` in the `TVarConstraints` dict
    - Store `name → tvarId` in a `Dict Name TVarId` mapping
  - Return both `TVarConstraints` and the `Dict Name TVarId` name-to-id mapping
- The name-to-id mapping bridges the Name-keyed world (substitution, Can.Type) to the Int-keyed world (TVarConstraints)

**Step 4.3 — Extend monomorphize signatures**
- Legacy: `monomorphize : Name -> TypeEnv.GlobalTypeEnv -> TVarConstraints -> Dict Name TVarId -> TOpt.GlobalGraph -> Result String Mono.MonoGraph`
- MonoDirect: `monomorphizeDirect : Name -> TypeEnv.GlobalTypeEnv -> SolverSnapshot -> TVarConstraints -> Dict Name TVarId -> TOpt.GlobalGraph -> Result String Mono.MonoGraph`
- Pass `TVarConstraints` and `Dict Name TVarId` through to TypeSubst and Specialize

**Step 4.4 — Replace `constraintFromName` calls with side-table lookups**
- At each call site, look up the tvar name in the `Dict Name TVarId` mapping, then use `Id.toComparable` to key into `TVarConstraints`:
  ```elm
  lookupConstraint : Dict Name TVarId -> TVarConstraints -> Name -> Mono.Constraint
  lookupConstraint nameToId tvarConstraints name =
      case Dict.get name nameToId of
          Just tvarId -> Dict.get (Id.toComparable tvarId) tvarConstraints |> Maybe.withDefault Mono.CEcoValue
          Nothing -> Mono.CEcoValue
  ```
- `TypeSubst.elm` (5 call sites): Replace `constraintFromName name` with `lookupConstraint` helper
- `KernelAbi.elm` (1 call site): Same pattern
- `Specialize.elm` (1 call site in `hasCEcoTVar`): Same pattern

**Step 4.5 — Delete `constraintFromName` from TypeSubst.elm and KernelAbi.elm**
- After all call sites are converted, remove the functions
- Keep `Name.isNumberType` (used by solver, Deps/Diff — upstream, unrelated)

### Phase 5: FreeVars Full Restructure

**Step 5.1 — Change `Can.FreeVars` definition** (Canonical.elm:274)
- From: `type alias FreeVars = Dict Name ()`
- To:
  ```elm
  type alias FreeVars =
      { displayNames : Dict Name ()
      , constraints : Dict Int Mono.Constraint
      }
  ```
- `displayNames` — cosmetic only, for error messages and debug printing
- `constraints` — keyed by `Id.toComparable tvarId`, semantic source of truth

**Step 5.2 — Update all `Forall` construction sites**
- Every place that builds `Forall freeVars type` must now build the record
- Transitional: at construction time, populate `constraints` by iterating `displayNames` and calling `constraintFromName` on each name (this will be the last remaining use of name-based constraint derivation, removed when solver emits constraints directly)
- Search for all `Forall` constructors in the codebase and update

**Step 5.3 — Update `hasCEcoTVar`** (Specialize.elm:386)
- Change to use `freeVars.constraints` directly:
  ```elm
  hasCEcoTVar : Can.FreeVars -> Can.Type -> Bool
  hasCEcoTVar freeVars canType =
      let vars = TypeSubst.collectCanTypeVars canType []
      in List.any (\tvarId ->
          case Dict.get (Id.toComparable tvarId) freeVars.constraints of
              Just Mono.CEcoValue -> True
              Nothing -> True  -- unknown = unconstrained = CEcoValue
              _ -> False
      ) vars
  ```

**Step 5.4 — Update `buildSchemeInfo`** (TypeSubst.elm:781)
- Accept `Can.FreeVars` and use `freeVars.constraints` instead of computing constraints via `constraintFromName`

**Step 5.5 — Update all FreeVars consumers**
- Pattern matches on `Forall freeVars _` that treat freeVars as `Dict Name ()` → update to use `.displayNames` or `.constraints` as appropriate
- Any `Dict.member name freeVars` → `Dict.member name freeVars.displayNames`

### Phase 6: Can.Type Parameterization and TVarId Assignment Pass

> Big but mechanical. Parameterize `Can.Type` over the tvar identifier type, then add a global pass that rewrites `Type Name` → `Type TVarId`.

**Step 6.1 — Parameterize `Can.Type`** (Canonical.elm)
- From:
  ```elm
  type Type = TLambda Type Type | TVar Name | TType ... | TRecord ... | TUnit | TTuple ... | TAlias ...
  ```
- To:
  ```elm
  type Type id = TLambda (Type id) (Type id) | TVar id | TType IO.Canonical Name (List (Type id)) | ...
  ```
- Introduce aliases:
  ```elm
  type alias TypeWithName = Type Name          -- used everywhere today
  type alias TypeWithTVarId = Type TVarId      -- used after interning pass
  ```

**Step 6.2 — Mechanical update of all `Can.Type` references**
- Every module that imports/uses `Can.Type` must be updated to use `Can.TypeWithName` (or the parameterized form)
- This is purely mechanical — no logic changes, just type annotations
- Estimate: touches most compiler modules but each change is trivial

**Step 6.3 — Implement `TVarInterning.internGlobalGraphTVars`**
- New module: `Compiler/AST/TypedOptimized/TVarInterning.elm`
- Signature: `internGlobalGraphTVars : TOpt.GlobalGraph -> ( TOpt.GlobalGraph, TVarConstraints, Dict Name TVarId )`
- Walks entire GlobalGraph with a single `Supply TVarPh`
- For each `Can.TVar name`:
  - If name already seen → reuse existing TVarId
  - If new → allocate fresh TVarId, derive constraint via `constraintFromName name` (one-time seeding), store both
- Rewrites `Can.Type Name` → `Can.Type TVarId` inside the graph (the TypedOptimized `Meta.tipe` field)
- Returns the rewritten graph + `TVarConstraints` + name-to-id mapping

**Step 6.4 — Wire into pipeline**
- In `Builder/Generate.elm`, after assembling GlobalGraph and before monomorphization:
  ```elm
  let
      ( globalGraphWithIds, tvarConstraints, nameToTVarId ) =
          TVarInterning.internGlobalGraphTVars globalGraph
  in
  Monomorphize.monomorphize mainName typeEnv tvarConstraints nameToTVarId globalGraphWithIds
  ```
- After this pass, all types in the GlobalGraph use `TVarId` instead of `Name`
- The `nameToTVarId` mapping bridges the Name-keyed substitution to the Int-keyed TVarConstraints
- Note: Substitution stays `Dict Name MonoType` — the name-to-id bridge is only used for constraint lookups, not for substitution keys

**Step 6.5 — Update TypedOptimized Meta to use parameterized type**
- `Meta.tipe : Can.Type` → `Meta.tipe : Can.Type TVarId` (after interning pass runs)
- Or keep `Meta.tipe : Can.TypeWithName` in LocalGraph (pre-interning) and `Can.TypeWithTVarId` in GlobalGraph (post-interning)

**Step 6.6 — Remove transitional `constraintFromName` seeding from Phase 5**
- Once the interning pass is the source of truth, the `constraintFromName` calls in `Forall` construction (Step 5.2) can be removed
- Constraints flow from the interning pass → `TVarConstraints` → everywhere

---

## Execution Order

```
Phase 1  (new files, no breakage)
  ↓
Phase 2  (MVar type change — causes compilation errors across 10 files)
  ↓
Phase 3  (fix errors: supply threading, substitution key migration, error MVars)
  ↓
Phase 4  (constraint side-table, delete constraintFromName)
  ↓
Phase 5  (FreeVars full restructure)
  ↓
Phase 6  (Can.Type parameterization + TVarInterning pass)
```

Phases 2+3 are inseparable (MVar type change must be fixed immediately by supply threading).
Phase 4 naturally follows (constraint lookups are already broken by Phase 2/3).
Phase 5 builds on Phase 4's side-table.
Phase 6 is the final structural completion — can be a separate PR if desired, but is included in scope.

---

## Files Changed (estimated)

| File | Change Type | Complexity |
|------|------------|------------|
| `Compiler/Data/Id.elm` | **NEW** | Low |
| `Compiler/AST/TypeIds.elm` | **NEW** | Low |
| `Compiler/AST/TypedOptimized/TVarInterning.elm` | **NEW** | Medium |
| `Compiler/AST/Monomorphized.elm` | MVar type + helpers | Medium |
| `Compiler/Monomorphize/TypeSubst.elm` | Substitution type, MVar creation, constraint lookups | **High** |
| `Compiler/Monomorphize/State.elm` | Add supply to state | Low |
| `Compiler/Monomorphize/Monomorphize.elm` | Entry point signature, supply init | Medium |
| `Compiler/Monomorphize/Specialize.elm` | `hasCEcoTVar`, MVar patterns | Medium |
| `Compiler/Monomorphize/KernelAbi.elm` | `constraintFromName` removal, supply threading | Medium |
| `Compiler/MonoDirect/Specialize.elm` | MVar patterns, supply threading | Medium |
| `Compiler/MonoDirect/Monomorphize.elm` | Entry point signature | Low |
| `Compiler/Type/SolverSnapshot.elm` | Error MVar → `Result String MVarId` | Medium |
| `Compiler/Generate/MLIR/Types.elm` | MVar patterns (mechanical) | Low |
| `Compiler/Generate/MLIR/Context.elm` | MVar patterns (mechanical) | Low |
| `Compiler/Generate/MLIR/TypeTable.elm` | MVar patterns (mechanical) | Low |
| `Compiler/GlobalOpt/Staging/GraphBuilder.elm` | Debug name | Low |
| `Builder/Generate.elm` | Build constraint table, wire interning pass | Medium |
| `Compiler/AST/Canonical.elm` | FreeVars restructure + Type parameterization | **High** |
| `Compiler/AST/TypedOptimized.elm` | Meta.tipe type update | Medium |
| Many modules (Phase 6) | `Can.Type` → `Can.TypeWithName` mechanical updates | Low each, **High** total |

**~20 files** for Phases 1–5, plus a large mechanical sweep for Phase 6.
