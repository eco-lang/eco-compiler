# Monomorphize Module Refactoring Plan

## Overview

Refactor the 3147-line `Compiler/Generate/Monomorphize.elm` into focused modules following Parnas principles, separating **monomorphization proper** (backend-agnostic type specialization) from **layout computation** (backend-specific memory layout decisions).

### Key Design Decisions

1. **Shape types** defined in new `Compiler/AST/LayoutShapes.elm`
2. **Two-phase approach**: Entry produces `MonoGraphNoLayout`, Layout phase produces `MonoGraph`
3. **Incremental migration**: Create parallel shape types first, gradually migrate
4. **Field ordering is backend-specific**: Belongs in `Layout.elm`, not core monomorphization
5. **MonoGraphNoLayout includes union types only**: Ctor layouts computed in layout phase
6. **KernelAbi stays layout-aware**: It's backend-specific, conceptually part of layout phase
7. **Tests unchanged**: Re-run existing tests to confirm identical behavior

---

## Phase 0: Define Shape Types

**Create:** `Compiler/AST/LayoutShapes.elm`

**Contents:**
```elm
module Compiler.AST.LayoutShapes exposing
    ( MRecordShape
    , MTupleShape
    , CtorShape
    )

import Compiler.AST.Monomorphized as Mono
import Data.Name exposing (Name)
import Dict

{-| Backend-agnostic record shape: field names and types without layout info.
-}
type alias MRecordShape =
    { fields : Dict.Dict String Name Mono.MonoType
    }

{-| Backend-agnostic tuple shape: element types without unboxing info.
-}
type alias MTupleShape =
    { elements : List Mono.MonoType
    }

{-| Backend-agnostic constructor shape: name, tag, field types without layout.
-}
type alias CtorShape =
    { name : Name
    , tag : Int
    , fieldTypes : List Mono.MonoType
    }
```

**Rationale:** These types capture the semantic structure without backend-specific layout decisions (field ordering, unboxing bitmaps, etc.).

**Build verification:** `cmake --build build`

---

## Phase 1: Extract State Module

**Create:** `Compiler/Generate/Monomorphize/State.elm`

**Contents:**
- `MonoState` type alias
- `Substitution` type alias
- `VarTypes` type alias
- `initialState` - create initial state
- `stateWithMain` - add main entry info
- `finalState` - extract final state
- Fresh variable/lambda ID generation helpers

**Functions to move from Monomorphize.elm:**
- Lines ~225-280: State type definitions and initializers
- `mainKey`, `mainSpecId`, `mainInfo` helpers

**Rationale:** State threading is foundational; other modules depend on it.

**Build verification:** `cmake --build build`

---

## Phase 2: Extract TypeSubst Module

**Create:** `Compiler/Generate/Monomorphize/TypeSubst.elm`

**Contents:**
- `applySubst : Substitution -> Mono.MonoType -> Mono.MonoType`
- `unify : Substitution -> Can.Type -> Mono.MonoType -> Substitution`
- `unifyHelp : Substitution -> Can.Type -> Mono.MonoType -> Substitution`
- `unifyFuncCall : Substitution -> Can.Type -> Mono.MonoType -> ( Substitution, Mono.MonoType )`
- `unifyArgsOnly : Substitution -> List Can.Type -> List Mono.MonoType -> Substitution`
- `canTypeToMonoType : Substitution -> Can.Type -> Mono.MonoType` (shape-based version)
- `constraintFromName : Name -> Mono.Constraint`

**Functions to move from Monomorphize.elm:**
- Lines ~2230-2540: Type unification and substitution functions

**Rationale:** Type substitution is a cohesive concern used throughout specialization.

**Build verification:** `cmake --build build`

---

## Phase 3: Extract Closure Module

**Create:** `Compiler/Generate/Monomorphize/Closure.elm`

**Contents:**
- `computeClosureCaptures : Dict.Dict String Name ( String, Mono.MonoType ) -> Mono.MonoExpr -> List ( Name, Mono.MonoType )`
- `findFreeLocals : Set.Set String Name -> Mono.MonoExpr -> Set.Set String Name`
- `collectDeciderFreeLocals : Set.Set String Name -> Mono.Decider a -> Set.Set String Name`
- `makeAliasClosure` - create closure for alias
- `makeGeneralClosure` - create general closure
- `makeAliasClosureOverExpr` - closure over expression
- `dedupeNames` - deduplicate captured names

**Functions to move from Monomorphize.elm:**
- Lines ~1740-1920: Closure capture analysis functions

**Rationale:** Closure capture analysis is a distinct, self-contained concern.

**Build verification:** `cmake --build build`

---

## Phase 4: Extract Analysis Module

**Create:** `Compiler/Generate/Monomorphize/Analysis.elm`

**Contents:**
- `collectDepsHelp : Mono.MonoExpr -> List Mono.SpecId -> List Mono.SpecId`
- `collectDeciderDeps : Mono.Decider Mono.MonoChoice -> List Mono.SpecId -> List Mono.SpecId`
- `collectCustomTypesFromMonoType : Mono.MonoType -> Set comparable -> Set comparable`
- `collectCustomTypesFromExpr : Mono.MonoExpr -> Set comparable -> Set comparable`
- `collectAllCustomTypes : Dict Int Int Mono.MonoNode -> Set comparable`
- `collectCustomTypesFromDecider : Mono.Decider Mono.MonoChoice -> Set comparable -> Set comparable`
- `lookupUnion : TypeEnv.GlobalTypeEnv -> IO.Canonical -> Name -> Maybe Can.Union`

**Functions to move from Monomorphize.elm:**
- Lines ~2750-2950: Dependency and custom type collection

**Rationale:** Analysis passes are separable from the main specialization logic.

**Build verification:** `cmake --build build`

---

## Phase 5: Extract Specialize Module (Largest)

**Create:** `Compiler/Generate/Monomorphize/Specialize.elm`

**Contents:**

### Core Specialization
- `specializeNode : MonoState -> Mono.SpecId -> TOpt.Node -> ( Mono.MonoNode, MonoState )`
- `specializeExpr : Substitution -> MonoState -> TOpt.Expr -> ( Mono.MonoExpr, MonoState )`
- `specializeExprs : Substitution -> MonoState -> List TOpt.Expr -> ( List Mono.MonoExpr, MonoState )`
- `specializeNamedExprs : Substitution -> MonoState -> List ( Name, TOpt.Expr ) -> ( List ( Name, Mono.MonoExpr ), MonoState )`

### Branch/Pattern Specialization
- `specializeBranches : Substitution -> MonoState -> List ( TOpt.Expr, TOpt.Expr ) -> ( List ( Mono.MonoExpr, Mono.MonoExpr ), MonoState )`
- `specializeDef : Substitution -> MonoState -> TOpt.Def -> ( Mono.MonoDef, MonoState )`
- `specializeDestructor : Substitution -> MonoState -> Can.PatternCtorArg -> ( Mono.MonoDestructor, MonoState )`
- `specializePath : Can.Path -> Mono.MonoPath`

### Decider Specialization
- `specializeDecider : Substitution -> VarTypes -> MonoState -> DT.Decider DT.Choice -> ( Mono.Decider Mono.MonoChoice, MonoState )`
- `specializeChoice : Substitution -> MonoState -> DT.Choice -> ( Mono.MonoChoice, MonoState )`
- `specializeEdges : Substitution -> VarTypes -> MonoState -> List ( DT.Test, DT.Decider DT.Choice ) -> ( List ( DT.Test, Mono.Decider Mono.MonoChoice ), MonoState )`
- `specializeJumps : Substitution -> VarTypes -> MonoState -> List ( Int, TOpt.Expr ) -> ( List ( Int, Mono.MonoExpr ), MonoState )`

### Record/Tuple Specialization (Shape-based)
- `specializeRecordFields : Dict String Name TOpt.Expr -> Substitution -> MonoState -> ( List ( Name, Mono.MonoExpr ), MonoState )`
- `specializeTrackedRecordFields : Dict String (A.Located Name) TOpt.Expr -> Substitution -> MonoState -> ( List ( Name, Mono.MonoExpr ), MonoState )`
- `specializeUpdates : Dict String (A.Located Name) TOpt.Expr -> Substitution -> MonoState -> ( List ( Name, Mono.MonoExpr ), MonoState )`

### Cycle Specialization
- `specializeCycle : Substitution -> MonoState -> List TOpt.Def -> ( List Mono.MonoDef, MonoState )`
- `specializeValueOnlyCycle : Substitution -> MonoState -> List TOpt.Def -> ( List Mono.MonoDef, MonoState )`
- `specializeFunctionCycle : ...`

### Helpers
- `specializeArg : Substitution -> MonoState -> TOpt.Expr -> Mono.MonoType -> ( Mono.MonoExpr, MonoState )`
- `ensureCallableTopLevel : MonoState -> Mono.Global -> Mono.MonoType -> Maybe Mono.LambdaId -> ( Mono.SpecId, MonoState )`
- `flattenFunctionType : Mono.MonoType -> ( List Mono.MonoType, Mono.MonoType )`
- `isFunctionType : Mono.MonoType -> Bool`

**Functions to move from Monomorphize.elm:**
- Lines ~350-750: Node specialization
- Lines ~760-1700: Expression specialization (bulk of the file)
- Lines ~1920-2140: Record/tuple field specialization
- Lines ~2000-2200: Decider specialization

**Note:** This module produces **shape-based** expressions. Record creates become `MonoRecordCreateShape` with field names (not indices), tuple creates become `MonoTupleCreateShape` without unboxing info.

**Rationale:** Expression specialization is the core algorithm; large enough for its own module.

**Build verification:** `cmake --build build`

---

## Phase 6: Extract Entry Module

**Create:** `Compiler/Generate/Monomorphize/Entry.elm`

**Contents:**
- `WorkItem` type (currently in Monomorphize.elm)
- `monomorphize : Mode.Mode -> TypeEnv.GlobalTypeEnv -> TOpt.Graph -> MonoGraphNoLayout`
- `monomorphizeFromEntry : Mode.Mode -> TypeEnv.GlobalTypeEnv -> TOpt.Graph -> Mono.Global -> MonoGraphNoLayout`
- `processWorklist : MonoState -> List WorkItem -> MonoState`
- `findEntryPoint : TOpt.Graph -> Maybe Mono.Global`
- `initState : Mode.Mode -> TypeEnv.GlobalTypeEnv -> TOpt.Graph -> MonoState`

**Functions to move from Monomorphize.elm:**
- Lines ~135-220: Entry point functions
- Lines ~280-350: Worklist processing

**Key change:** `monomorphize` returns `MonoGraphNoLayout` instead of `MonoGraph`. The graph contains:
- `nodes : Dict Int Int MonoNodeNoLayout`
- `main : Maybe MainInfo`
- `registry : SpecializationRegistry`
- `customTypes : Set comparable` (union types referenced, for layout phase)

**Rationale:** Entry module orchestrates the process, depends on all other modules.

**Build verification:** `cmake --build build`

---

## Phase 7: Create Layout Module

**Create:** `Compiler/Generate/Layout.elm`

**Contents:**

### Main Entry Point
```elm
computeLayouts : TypeEnv.GlobalTypeEnv -> MonoGraphNoLayout -> Mono.MonoGraph
```

### Record Layout
- `computeRecordLayout : LayoutShapes.MRecordShape -> Mono.RecordLayout`
- `getRecordLayout : Mono.MonoType -> Mono.RecordLayout`
- Field ordering logic (unboxed-first, alphabetical within groups)

### Tuple Layout
- `computeTupleLayout : LayoutShapes.MTupleShape -> Mono.TupleLayout`
- `getTupleLayout : Mono.MonoType -> Mono.TupleLayout`

### Constructor Layout
- `buildCtorLayoutFromArity : Name -> Int -> Int -> Mono.MonoType -> Mono.CtorLayout`
- `buildCtorLayoutFromUnion : Substitution -> Can.Ctor -> Mono.CtorLayout`
- `buildCompleteCtorLayouts : List Name -> List Mono.MonoType -> List Can.Ctor -> List Mono.CtorLayout`
- `computeCtorLayoutsForGraph : TypeEnv.GlobalTypeEnv -> Set comparable -> Dict comparable (List Mono.CtorLayout)`

### Node/Expression Transformation
- `addLayoutToNode : MonoNodeNoLayout -> Mono.MonoNode`
- `addLayoutToExpr : MonoExprNoLayout -> Mono.MonoExpr`

**Functions to move:**
- From `Monomorphize.elm` lines ~2547-2700: `getRecordLayout`, `getTupleLayout`, `buildCtorLayoutFromArity`
- From `Monomorphize.elm` lines ~3040-3140: `buildCompleteCtorLayouts`, `buildCtorLayoutFromUnion`, `computeCtorLayoutsForGraph`
- From `Monomorphized.elm` lines ~581-680: `computeRecordLayout`, `computeTupleLayout`

**Rationale:** Layout computation is backend-specific (MLIR field ordering). Separating it makes monomorphization backend-agnostic and allows future backends to use different layout strategies.

**Build verification:** `cmake --build build`

---

## Phase 8: Update KernelAbi Module

**Location:** `Compiler/Generate/Monomorphize/KernelAbi.elm`

**Changes:**
- Move to `Compiler/Generate/Layout/KernelAbi.elm` (conceptually part of layout phase)
- Keep returning layout-bearing types (it's backend-specific)
- Update imports to use new module locations

**Rationale:** KernelAbi is backend-specific, conceptually part of the layout phase.

**Build verification:** `cmake --build build`

---

## Phase 9: Create Monomorphize Shim

**Update:** `Compiler/Generate/Monomorphize.elm`

**New contents (~30 lines):**
```elm
module Compiler.Generate.Monomorphize exposing (monomorphize, monomorphizeFromEntry)

{-| Monomorphization entry point.

This module re-exports from the modular implementation.
-}

import Compiler.AST.Monomorphized as Mono
import Compiler.AST.TypeEnv as TypeEnv
import Compiler.Generate.Layout as Layout
import Compiler.Generate.Mode as Mode
import Compiler.Generate.Monomorphize.Entry as Entry
import Compiler.TypedOptimize as TOpt


monomorphize : Mode.Mode -> TypeEnv.GlobalTypeEnv -> TOpt.Graph -> Mono.MonoGraph
monomorphize mode typeEnv graph =
    Entry.monomorphize mode typeEnv graph
        |> Layout.computeLayouts typeEnv


monomorphizeFromEntry : Mode.Mode -> TypeEnv.GlobalTypeEnv -> TOpt.Graph -> Mono.Global -> Mono.MonoGraph
monomorphizeFromEntry mode typeEnv graph entry =
    Entry.monomorphizeFromEntry mode typeEnv graph entry
        |> Layout.computeLayouts typeEnv
```

**Rationale:** Maintains backward compatibility; existing callers see the same API.

**Build verification:** `cmake --build build`

---

## Phase 10: Integration and Final Testing

**Steps:**
1. Run full test suite: `cmake --build build && ./build/test/test`
2. Verify all tests pass with identical results
3. Run elm-format on all new files: `npm run elm-format`
4. Clean up any unused imports or dead code

**Validation criteria:**
- All existing tests pass without modification
- Compiler produces identical output for all test programs
- No new warnings from elm-make

---

## Dependency Graph

```
LayoutShapes.elm (Phase 0)
    │
    ▼
State.elm (Phase 1)
    │
    ├──────────────┐
    ▼              ▼
TypeSubst.elm    Analysis.elm
(Phase 2)        (Phase 4)
    │              │
    ▼              │
Closure.elm ◄──────┘
(Phase 3)
    │
    ▼
Specialize.elm (Phase 5)
    │
    ▼
Entry.elm (Phase 6) ──► MonoGraphNoLayout
    │
    ▼
Layout.elm (Phase 7) ──► MonoGraph
    │
    ├── KernelAbi.elm (Phase 8)
    │
    ▼
Monomorphize.elm shim (Phase 9)
```

---

## File Summary

| Phase | File | Action | Est. Lines |
|-------|------|--------|------------|
| 0 | `Compiler/AST/LayoutShapes.elm` | Create | ~50 |
| 1 | `Compiler/Generate/Monomorphize/State.elm` | Create | ~150 |
| 2 | `Compiler/Generate/Monomorphize/TypeSubst.elm` | Create | ~300 |
| 3 | `Compiler/Generate/Monomorphize/Closure.elm` | Create | ~250 |
| 4 | `Compiler/Generate/Monomorphize/Analysis.elm` | Create | ~200 |
| 5 | `Compiler/Generate/Monomorphize/Specialize.elm` | Create | ~1200 |
| 6 | `Compiler/Generate/Monomorphize/Entry.elm` | Create | ~250 |
| 7 | `Compiler/Generate/Layout.elm` | Create | ~400 |
| 8 | `Compiler/Generate/Layout/KernelAbi.elm` | Move+Update | ~200 |
| 9 | `Compiler/Generate/Monomorphize.elm` | Replace | ~30 |

**Total new code:** ~3000 lines across 10 files (vs. original 3147 in one file)

---

## Risk Mitigation

1. **Incremental approach:** Each phase produces a buildable, testable state
2. **No test modifications:** Tests validate behavioral equivalence
3. **Shape/Layout parallel types:** Existing layout types preserved during migration
4. **Thin shim:** Original module API preserved for callers

---

## Notes

- All functions preserve their existing signatures where possible
- Type annotations added/updated as needed for new module boundaries
- Import statements will use qualified imports to avoid name collisions
- elm-format applied to all files before committing each phase
