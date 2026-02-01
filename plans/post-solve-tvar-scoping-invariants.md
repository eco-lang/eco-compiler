# Plan: POST_005 and POST_006 - TVar Scoping Invariants

## Overview

This plan implements two new PostSolve invariants that detect polymorphic type variable residue issues:

- **POST_005**: Monomorphic defs have no TVar residue in NodeTypes
- **POST_006**: NodeTypes TVars are scoped by enclosing def's Forall

These invariants catch the exact polymorphic residue bug discovered during MONO_018 analysis, where pattern variable types in `nodeTypes` retain unresolved type variables like `MVar 2` that should have been unified to concrete types.

## Background

### Problem Discovery

During MONO_018 testing, 3 test failures showed polymorphic type residue:
- `polymorphicIdentityWithList`
- `polymorphicApplyWithListLiteral`
- `polymorphicComposeWithList`

The root cause: In PostSolve, when processing patterns like `let ( head, tail ) = ...`, the pattern variable types in `nodeTypes` (for the pattern variable expression IDs) retain unresolved type variables like `MVar 2` even in monomorphic contexts.

### Why PostSolve Phase

These invariants belong in PostSolve because:
1. PostSolve is responsible for fixing nodeTypes after solving
2. The bug manifests when nodeTypes contains TVars that weren't resolved during unification
3. Catching it at PostSolve prevents the issue from propagating to monomorphization

## Invariant Definitions

### POST_005: Monomorphic defs have no TVar residue

**Condition**: For any definition with an empty `Forall` (i.e., `Forall Dict.empty type`):
- ALL expression and pattern types within that def's scope must be TVar-free

**Rationale**: A monomorphic definition has no type parameters, so no type variables should appear in any subexpression types.

### POST_006: NodeTypes TVars are scoped by enclosing def's Forall

**Condition**: For any TVar appearing in a nodeType entry:
- The TVar name must appear in the `freeVars` of the enclosing definition's `Forall`
- OR the TVar must be bound by an enclosing let-polymorphic definition

**Rationale**: Every type variable in a type must be introduced somewhere. For top-level defs, that's the Forall. For let bindings, it can be inherited or locally bound.

## Implementation Plan

### Step 1: Update invariants.csv

Add entries after POST_004:

```csv
POST_005;PostSolve;Scoping;enforced;For definitions with Forall Dict.empty (monomorphic) all expression and pattern types in nodeTypes within that def scope must contain no TVar constructors ensuring monomorphic contexts have fully resolved types;Compiler.Type.PostSolve
POST_006;PostSolve;Scoping;enforced;Any TVar appearing in nodeTypes must be bound by the freeVars of an enclosing definition Forall ensuring type variables are properly scoped and not residual unification variables;Compiler.Type.PostSolve
```

### Step 2: Update invariant-test-logic.md

Add test logic documentation under PostSolve section.

### Step 3: Create Checker Module

**File**: `compiler/tests/Compiler/Type/PostSolve/TVarScoping.elm`

**Key exports**:
- `expectNoTVarResidueInMonomorphicDefs : Src.Module -> Expectation`
- `expectTVarsScopedByForall : Src.Module -> Expectation`
- `checkTVarScoping : PostSolveResult -> List Violation`

**Implementation approach**:

```elm
-- Check POST_005: Monomorphic defs have no TVar residue
checkMonomorphicDef : String -> Can.Annotation -> Set Int -> PostSolve.NodeTypes -> List Violation
checkMonomorphicDef defName (Can.Forall freeVars _) exprIds nodeTypes =
    if Dict.isEmpty freeVars then
        -- Monomorphic def: check all expressions have no TVars
        Set.foldl
            (\exprId acc ->
                case Dict.get identity exprId nodeTypes of
                    Just canType ->
                        acc ++ checkNoTVars defName exprId canType
                    Nothing ->
                        acc
            )
            []
            exprIds
    else
        []

-- Check POST_006: TVars scoped by Forall
checkTVarScoping : String -> Can.Annotation -> Set Int -> PostSolve.NodeTypes -> List Violation
checkTVarScoping defName (Can.Forall freeVars _) exprIds nodeTypes =
    let
        allowedVars = Dict.keys freeVars |> Set.fromList
    in
    Set.foldl
        (\exprId acc ->
            case Dict.get identity exprId nodeTypes of
                Just canType ->
                    acc ++ checkTVarsInScope defName exprId allowedVars canType
                Nothing ->
                    acc
        )
        []
        exprIds
```

**Challenge**: Mapping expression IDs to their enclosing def

The tricky part is knowing which expression IDs belong to which def. Options:

1. **Walk the canonical AST**: Traverse each def body and collect all expression IDs encountered
2. **Track during traversal**: Build a map of exprId -> enclosing def as we walk

Recommended: Option 1 - Walk the canonical AST for each def, collecting expression IDs from the `Expr` tree.

### Step 4: Create Test Module

**File**: `compiler/tests/Compiler/Type/PostSolve/TVarScopingTest.elm`

```elm
module Compiler.Type.PostSolve.TVarScopingTest exposing (suite)

import Compiler.Type.PostSolve.TVarScoping exposing
    ( expectNoTVarResidueInMonomorphicDefs
    , expectTVarsScopedByForall
    )
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)

suite : Test
suite =
    Test.describe "POST_005/POST_006: TVar Scoping"
        [ StandardTestSuites.expectSuite expectNoTVarResidueInMonomorphicDefs "monomorphic defs have no TVar"
        , StandardTestSuites.expectSuite expectTVarsScopedByForall "TVars scoped by Forall"
        ]
```

### Step 5: Register in InvariantTests.elm

Add to `postSolveInvariants`:

```elm
postSolveInvariants : Test
postSolveInvariants =
    Test.describe "Post-Solve Invariants"
        [ GroupBTypesTest.suite -- POST_001
        , KernelTypesTest.suite -- POST_002
        , NoSyntheticVarsTest.suite -- POST_003
        , DeterminismTest.suite -- POST_004
        , TVarScopingTest.suite -- POST_005, POST_006
        ]
```

### Step 6: Add Import to InvariantTests.elm

```elm
import Compiler.Type.PostSolve.TVarScopingTest as TVarScopingTest
```

## Data Structures

### Violation Record

```elm
type alias Violation =
    { invariant : String  -- "POST_005" or "POST_006"
    , defName : String    -- Name of the enclosing definition
    , exprId : Int        -- The problematic expression ID
    , foundTVar : String  -- The TVar name found
    , context : String    -- Additional context
    }
```

### Key Helpers Needed

```elm
-- Extract all expression IDs from an Expr tree
collectExprIds : Can.Expr -> Set Int

-- Extract all pattern IDs from patterns
collectPatternIds : Can.Pattern -> Set Int

-- Check if a Can.Type contains any TVar
containsTVar : Can.Type -> Bool

-- Get all TVars in a Can.Type
getTVars : Can.Type -> Set String

-- Check if all TVars are in the allowed set
checkTVarsInScope : String -> Int -> Set String -> Can.Type -> List Violation
```

## Walking the Canonical AST

To map expression IDs to their enclosing def, we need to walk `Can.Decls`:

```elm
walkDecls : Can.Decls -> (String -> Can.Annotation -> Set Int -> a) -> List a
walkDecls decls checkDef =
    case decls of
        Can.Declare def rest ->
            let
                defName = getDefName def
                annotation = getDefAnnotation def
                exprIds = collectDefExprIds def
            in
            checkDef defName annotation exprIds :: walkDecls rest checkDef

        Can.DeclareRec def defs rest ->
            -- Handle recursive defs similarly
            ...

        Can.SaveTheEnvironment ->
            []
```

For `Can.Def`:
- `Def (A.Located Name) (List Pattern) Expr` - look up annotation in annotations dict
- `TypedDef (A.Located Name) FreeVars (List ( Pattern, Type )) Expr Type` - FreeVars is inline

## Expected Test Failures

Based on MONO_018 analysis, these tests should fail:
- `polymorphicIdentityWithList` - pattern variables have MVar residue
- `polymorphicApplyWithListLiteral` - similar issue
- `polymorphicComposeWithList` - similar issue

These failures indicate the checker is working correctly and detecting the known bug.

## Files to Create/Modify

### New Files
1. `compiler/tests/Compiler/Type/PostSolve/TVarScoping.elm` - Checker module
2. `compiler/tests/Compiler/Type/PostSolve/TVarScopingTest.elm` - Test suite

### Modified Files
1. `design_docs/invariants.csv` - Add POST_005, POST_006
2. `design_docs/invariant-test-logic.md` - Add test logic documentation
3. `compiler/tests/Compiler/InvariantTests.elm` - Register tests

## Open Questions

### Q1: Let-polymorphism scoping

For nested let-bindings that introduce local type variables, should POST_006 track a stack of Foralls?

Example:
```elm
topLevel : a -> a  -- Forall { a }
topLevel x =
    let
        localId : b -> b  -- Forall { b }
        localId y = y
    in
    localId x
```

Inside `localId` body, should `b` be allowed? (Yes, from its own Forall)
Inside `topLevel` body but outside `localId`, only `a` should be allowed.

**Suggested approach**: Track a scope stack of Forall freeVars as we traverse.

### Q2: Expression ID assignment (RESOLVED)

Expression IDs are stored in `Can.ExprInfo`:
```elm
type alias Expr = A.Located ExprInfo

type alias ExprInfo =
    { id : Int
    , node : Expr_
    }
```

To extract expression ID from `Can.Expr`:
```elm
getExprId : Can.Expr -> Int
getExprId (A.At _ exprInfo) = exprInfo.id
```

This is how PostSolve accesses them (line 338-339):
```elm
postSolveExpr annotations (A.At _ exprInfo) nodeTypes0 kernel0 =
    let
        exprId = exprInfo.id
    in ...
```

Patterns also have the same structure:
```elm
type alias Pattern = A.Located PatternInfo

type alias PatternInfo =
    { id : Int
    , node : Pattern_
    }
```

Both expression IDs and pattern IDs are stored in the same `nodeTypes` dictionary.

### Q3: Untyped vs Typed defs

For `Can.Def` (untyped), the annotation must be looked up in the `annotations` dict passed to PostSolve. Should we fail if an annotation is missing?

**Suggested approach**: Skip defs without annotations (they may be internal/compiler-generated).

### Q4: Kernel expressions

Kernel expressions (like `Kernel.Array.array`) have negative expression IDs. Should they be excluded from these checks?

**Suggested approach**: Yes, skip negative IDs as they are kernel internals.

## Next Steps After Plan Approval

1. Verify how expression IDs work in canonical AST
2. Implement the checker module
3. Run tests and verify the expected failures occur
4. Report results before any fixes
