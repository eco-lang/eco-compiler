# Plan: Strong POST_001 and POST_003 Invariant Tests with Synthetic Provenance

## Overview

This plan implements targeted invariant tests for POST_001 and POST_003 that can precisely detect "unfilled placeholder" bugs (Issue B from MONO_018 analysis). The key insight is to preserve metadata about which expression IDs had synthetic placeholder variables allocated during constraint generation.

### Problem Statement

Current POST_001/POST_003 tests:
- Check ALL nodeTypes instead of filtering to relevant nodes
- Cannot distinguish between legitimate polymorphic TVars and unfilled synthetic placeholders
- Have only 2-3 minimal hand-written tests instead of comprehensive coverage

The MONO_018 failures show polymorphic remnants (`MVar "a" CEcoValue`) that escape to monomorphization because PostSolve doesn't fill certain TVars. These are "Issue B" bugs that current tests miss.

### Key Insight

The typed constraint generator already distinguishes Group A vs Group B expressions. Group B uses the "generic path that allocates a synthetic exprVar". Today we throw away that provenance by only returning `NodeVarMap` (ID → variable). By preserving "this ID's solver variable was synthetic" metadata, tests can precisely detect unfilled placeholders.

## Goals

### POST_001 (Improved)
Verify that for Group B expressions whose solver output still contains a synthetic placeholder, PostSolve replaces that placeholder with the structural type implied by the AST + children's types.

### POST_003 (Improved)
Verify that after PostSolve, no unresolved synthetic placeholders remain in any non-kernel expression type anywhere in the type tree. This directly targets the MONO_018 "polymorphic remnant" class.

---

## Part A: Compiler Plumbing to Expose Synthetic Provenance

### Step A1: Extend NodeIdState to Record Synthetic Expression IDs

**File:** `compiler/src/Compiler/Type/Constrain/Typed/NodeIds.elm`

**Current state:**
```elm
type alias NodeIdState =
    { mapping : NodeVarMap }
```

**Change to:**
```elm
type alias NodeIdState =
    { mapping : NodeVarMap
    , syntheticExprIds : EverySet Int Int
    }

emptyNodeIdState : NodeIdState
emptyNodeIdState =
    { mapping = Dict.empty
    , syntheticExprIds = EverySet.empty
    }

recordNodeVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordNodeVar id var state =
    if id >= 0 then
        { state | mapping = Dict.insert identity id var state.mapping }
    else
        state

recordSyntheticExprVar : Int -> IO.Variable -> NodeIdState -> NodeIdState
recordSyntheticExprVar id var state =
    if id >= 0 then
        { state
            | mapping = Dict.insert identity id var state.mapping
            , syntheticExprIds = EverySet.insert identity id state.syntheticExprIds
        }
    else
        state
```

**Rationale:** No production behavior changes; just richer metadata for testing.

### Step A2: Mark Group B Generic Expression Vars as Synthetic

**File:** `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm`

**Change:** In `constrainGenericWithIdsProg`, replace:
```elm
Prog.opModifyS (NodeIds.recordNodeVar info.id exprVar)
```

with:
```elm
Prog.opModifyS (NodeIds.recordSyntheticExprVar info.id exprVar)
```

This is the single most important code change. The generic-with-IDs path is exactly where synthetic placeholder variables are allocated for Group B expressions.

### Step A3: Add Detailed Constraint-Generation Entry Point

**File:** `compiler/src/Compiler/Type/Constrain/Typed/Module.elm`

**Add new function:**
```elm
constrainWithIdsDetailed : Can.Module -> IO ( Constraint, NodeIds.NodeIdState )
constrainWithIdsDetailed canonical =
    -- Implementation that returns full NodeIdState instead of just mapping
    ...

-- Keep existing API stable:
constrainWithIds : Can.Module -> IO ( Constraint, NodeIds.NodeVarMap )
constrainWithIds canonical =
    constrainWithIdsDetailed canonical
        |> IO.map (\( con, state ) -> ( con, state.mapping ))
```

**Rationale:** Tests need access to `syntheticExprIds`, but production code continues using the existing API.

### Step A4: Update Documentation

**File:** `design_docs/invariant-test-logic.md`

Add `tests:` entries under POST_001 and POST_003 blocks:
- POST_001: `tests: compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`
- POST_003: `tests: compiler/tests/Compiler/Type/PostSolve/PostSolveNoSyntheticHolesTest.elm`

---

## Part B: POST_001 Test Implementation

### New File: `compiler/tests/Compiler/Type/PostSolve/PostSolveGroupBStructuralTypesTest.elm`

#### Pipeline for Each Test Module

1. `ConstrainTyped.constrainWithIdsDetailed canonical` → `(constraint, nodeState)`
2. `Solve.runWithIds constraint nodeState.mapping` → `Ok { annotations, nodeTypes = nodeTypesPre }`
3. `PostSolve.postSolve annotations canonical nodeTypesPre` → `nodeTypesPost`

#### Identify Which Group B Expression IDs to Check

For each `exprId ∈ nodeState.syntheticExprIds`:
1. Let `preType = nodeTypesPre[exprId]`
2. If `preType` is `Can.TVar _`, that indicates the solver left a placeholder hole
3. Also verify `exprId` corresponds to a Group B expression by checking the AST node type

Group B expressions (from PostSolve spec):
- Str, Chr, Float, Unit
- List, Tuple, Record
- Lambda, Accessor
- Let, LetRec, LetDestruct

#### Structural Recomputation Oracle

For each Group B expression with a placeholder hole, compute `expectedType` using only:
- The expression AST node
- `nodeTypesPost` of its subexpressions/patterns

Expected structural rules:

| Expression | Expected Type |
|------------|---------------|
| Str | `Can.TType ModuleName.string Name.string []` |
| Chr | `Can.TType ModuleName.char Name.char []` |
| Float | `Can.TType ModuleName.basics Name.float []` |
| Unit | `Can.TUnit` |
| List (empty) | `Can.TType ModuleName.list Name.list [Can.TVar "a"]` |
| List (non-empty) | `Can.TType ModuleName.list Name.list [nodeTypesPost[firstElemId]]` |
| Tuple | `Can.TTuple aType bType csTypes` |
| Record | `Can.TRecord fieldTypes Nothing` |
| Lambda | `List.foldr Can.TLambda bodyType argTypes` |
| Accessor | `{ ext \| field : a } -> a` |
| Let/LetRec/LetDestruct | `nodeTypesPost[bodyId]` |

**Assertion:** `nodeTypesPost[exprId]` must be alpha-equivalent to `expectedType`.

---

## Part C: POST_003 Test Implementation

### New File: `compiler/tests/Compiler/Type/PostSolve/PostSolveNoSyntheticHolesTest.elm`

#### Pipeline

Same as POST_001:
1. `constrainWithIdsDetailed` → `(constraint, nodeState)`
2. `Solve.runWithIds` → `nodeTypesPre`
3. `PostSolve.postSolve` → `nodeTypesPost`

#### Compute Set of Hole Variable Names

```elm
holeVarNames : Set String
holeVarNames =
    nodeState.syntheticExprIds
        |> EverySet.toList identity
        |> List.filterMap (\exprId ->
            case Dict.get identity exprId nodeTypesPre of
                Just (Can.TVar name) -> Just name
                _ -> Nothing
        )
        |> EverySet.fromList identity
```

This "learns" which solver TVars were left unresolved at synthetic Group B sites.

#### Classify Kernel Expression IDs

Traverse the Canonical AST and build:
```elm
kernelExprIds : Set Int
kernelExprIds =
    -- IDs where the node is Can.VarKernel _ _
```

These are exempt from the "no hole vars" check per POST_003 spec.

#### Assertion for Each Expression ID

For each expression `exprId` in the canonical module:
1. `postType = nodeTypesPost[exprId]`
2. If `exprId ∉ kernelExprIds`:
   - Assert: `freeVars(postType) ∩ holeVarNames == ∅`

This catches the MONO_018 "remnant TVar becomes MVar" pathway because it flags a solver-hole var even when nested inside a function return, list element, etc.

---

## Part D: Shared Test Helpers

### New File: `compiler/tests/Compiler/Type/PostSolve/PostSolveInvariantHelpers.elm`

```elm
module Compiler.Type.PostSolve.PostSolveInvariantHelpers exposing
    ( walkExprs
    , isGroupBExprNode
    , isVarKernel
    , freeVars
    , collectExprIds
    )

-- Walk all expressions in a module
walkExprs : Can.Module -> List ( Int, Can.Expr_ )

-- Check if an expression node is Group B
isGroupBExprNode : Can.Expr_ -> Bool
isGroupBExprNode node =
    case node of
        Can.Str _ -> True
        Can.Chr _ -> True
        Can.Float _ -> True
        Can.Unit -> True
        Can.List _ -> True
        Can.Tuple _ _ _ -> True
        Can.Record _ -> True
        Can.Lambda _ _ -> True
        Can.Accessor _ -> True
        Can.Let _ _ -> True
        Can.LetRec _ _ -> True
        Can.LetDestruct _ _ _ -> True
        _ -> False

-- Check if expression is VarKernel
isVarKernel : Can.Expr_ -> Bool
isVarKernel node =
    case node of
        Can.VarKernel _ _ -> True
        _ -> False

-- Extract free type variables from a type
freeVars : Can.Type -> EverySet String String
-- (Implementation similar to PostSolveNonRegressionInvariants.freeTypeVars)
```

---

## Part E: Implementation Checklist

### Compiler (Production) Code Changes

| Step | File | Change |
|------|------|--------|
| A1 | `Compiler/Type/Constrain/Typed/NodeIds.elm` | Add `syntheticExprIds` field, add `recordSyntheticExprVar` |
| A2 | `Compiler/Type/Constrain/Typed/Expression.elm` | Call `recordSyntheticExprVar` in `constrainGenericWithIdsProg` |
| A3 | `Compiler/Type/Constrain/Typed/Module.elm` | Add `constrainWithIdsDetailed` returning full `NodeIdState` |
| A4 | `design_docs/invariant-test-logic.md` | Add `tests:` entries for POST_001, POST_003 |

### New Test Files

| Step | File | Purpose |
|------|------|---------|
| B1 | `PostSolve/PostSolveGroupBStructuralTypesTest.elm` | POST_001: Group B structural type verification |
| C1 | `PostSolve/PostSolveNoSyntheticHolesTest.elm` | POST_003: No hole vars in non-kernel types |
| D1 | `PostSolve/PostSolveInvariantHelpers.elm` | Shared AST traversal and utility functions |

### Modified Test Files

| File | Change |
|------|--------|
| `Compiler/InvariantTests.elm` | Register new test suites for POST_001, POST_003 |

---

## Known Risk and Mitigation

**Risk:** POST_003 uses "hole var names" extracted from `nodeTypesPre[exprId]` where it's a `Can.TVar name`. If the solver's `Type.toCanType` names a synthetic hole `"a"` (colliding with PostSolve's own `"a"` used in empty list/accessor logic), you could get false positives.

**Mitigation options:**
1. Refine hole collection to include only names matching the solver's generated var naming convention (if one exists)
2. Extend the solver conversion path to emit a reserved prefix for unconstrained vars from `syntheticExprIds` (larger change; only if needed)

---

## Expected Outcomes

After implementation:
1. **POST_001** will verify Group B expressions get exactly the structural types computed from their AST + children's types
2. **POST_003** will catch any synthetic placeholder TVars that leak through PostSolve into non-kernel expression types
3. The MONO_018 "polymorphic remnant" failures will be detectable at the PostSolve phase (earlier in the pipeline)

---

## Open Questions (Resolved)

### Q1: Exact Location of `constrainGenericWithIdsProg` (RESOLVED)

**Location:** `compiler/src/Compiler/Type/Constrain/Typed/Expression.elm:404-409`

```elm
constrainGenericWithIdsProg : RigidTypeVar -> A.Region -> Can.ExprInfo -> E.Expected Type -> ProgS ExprIdState Constraint
constrainGenericWithIdsProg rtv region info expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\exprVar ->
                Prog.opModifyS (NodeIds.recordNodeVar info.id exprVar)  -- CHANGE THIS LINE
                ...
```

**Change:** Replace `NodeIds.recordNodeVar` with `NodeIds.recordSyntheticExprVar` on line 409.

**Note:** There are ~15 other `recordNodeVar` calls in the file for specific expression types (Number, Float, Access, Binop, If, Case, Call, Update). These should remain unchanged as they have their own natural result variables.

### Q2: NodeIdState Export (RESOLVED)

Current `NodeIdState` is already a type alias exposed from `NodeIds.elm`. The pattern should be:
- Keep `NodeIdState` exposed as a type alias (tests need to access `.syntheticExprIds`)
- Add `recordSyntheticExprVar` to the export list
- This follows the existing pattern in the module

### Q3: Test Coverage Scope (RESOLVED)

Use `StandardTestSuites.expectSuite` for comprehensive coverage, following the pattern established by POST_005/POST_006 (`PostSolveNonRegressionInvariantsTest.elm`). This ensures the invariants are tested against the full corpus of test modules.

### Q4: Hole Name Collision Check (RESOLVED)

Looking at the solver's variable naming: solver-generated TVars use numeric names (e.g., "0", "1", "23") while PostSolve uses alphabetic names (e.g., "a", "ext"). There should be no collision. The `isSyntheticVarName` pattern in existing code (`Char.isDigit first`) confirms this convention.

**Low risk:** The hole var collection can safely use any TVar name from pre-PostSolve synthetic expression IDs.
