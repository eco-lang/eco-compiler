# Plan: Corrected PostSolve Invariants (POST_005/POST_006) - Non-Regression Approach

## Overview

This plan replaces the earlier "TVar scoping" invariants with **non-regression** invariants that are valid for a Hindley-Milner pipeline and directly catch the real bug class: PostSolve overwriting solver-inferred concrete types with more-polymorphic ones.

### Motivating Example

The key bug is in `postSolveList`, which forces `[]` to have element type `TVar "a"` and writes `List a` into `nodeTypes`, even if the solver already inferred `List Int`.

### Why the Earlier Approach Was Wrong

The earlier POST_005/POST_006 invariants checked:
- POST_005: Monomorphic defs have no TVar residue
- POST_006: TVars are scoped by enclosing Forall

These are **invalid for HM** because:
- PostSolve assigns accessors a deliberately polymorphic type `{ ext | field : a } -> a`
- Polymorphic type variables are legitimate in polymorphic function bodies
- The 106 test failures were false positives, not real bugs

## Redefined Invariants

### POST_005 (Redefined): Non-Regression for Structured Types

**Definition**: For every non-negative expression/pattern node ID whose solver-produced (pre-PostSolve) type is **not** a bare `Can.TVar`, PostSolve must not change that node's type (alpha-equivalent).

**Exceptions**:
- VarKernel nodes: Their types may be inferred/filled during PostSolve

**Rationale**: PostSolve's job is to fill missing Group B types (placeholders), not to undo solver constraints.

### POST_006 (Redefined): No New Free Type Variables

**Definition**: For every non-negative expression/pattern node ID, the set of free `Can.TVar` names in the post-PostSolve type must be a subset of those in the pre-PostSolve type.

**Exceptions**:
- VarKernel nodes: Types inferred from usage
- Accessor nodes: Intentionally assigned polymorphic `{ ext | field : a } -> a` type

**Rationale**: PostSolve cannot make a node more polymorphic than what the solver inferred. Cases like `List Int -> List a` are rejected.

## Key Insight: Pre vs Post Comparison

The earlier tests only saw the final `nodeTypes` (after PostSolve). These invariants require **both**:
- `nodeTypesPre` from the solver (`Solve.runWithIds`)
- `nodeTypesPost` from `PostSolve.postSolve`

## Implementation Plan

### Step 1: Update invariants.csv

**File**: `design_docs/invariants.csv`

Replace the existing POST_005 and POST_006 entries with:

```csv
POST_005;PostSolve;NonRegressionStructuredNodeTypes;enforced;For every non-negative expression/pattern node id whose solver-produced (pre-PostSolve) type is not a bare Can.TVar PostSolve must not change that node type (alpha-equivalent) except for VarKernel nodes whose types may be inferred/filled during PostSolve;Compiler.Type.PostSolve

POST_006;PostSolve;NoNewFreeTypeVars;enforced;For every non-negative expression/pattern node id (excluding VarKernel and Accessor nodes) the set of free Can.TVar names appearing in the node post-PostSolve type must be a subset of those appearing in its pre-PostSolve solver type ensuring PostSolve does not introduce new polymorphism;Compiler.Type.PostSolve
```

### Step 2: Update invariant-test-logic.md

**File**: `design_docs/invariant-test-logic.md`

Replace the POST_005/POST_006 blocks with:

```
--
name: PostSolve does not rewrite solver-structured node types
phase: post-solve
invariants: POST_005
ir: Solver NodeTypes (pre-PostSolve) vs PostSolve NodeTypes (post-PostSolve)
logic:
  * Run Solve.runWithIds to obtain nodeTypesPre.
  * Run PostSolve.postSolve to obtain nodeTypesPost.
  * Traverse the canonical module to classify node ids (VarKernel, Accessor, other).
  * For each node id >= 0 that is not VarKernel:
      - if nodeTypesPre[id] is NOT a bare TVar, assert nodeTypesPost[id] is alpha-equivalent to nodeTypesPre[id].
inputs: Canonical module + (annotations, nodeTypesPre) + nodeTypesPost
oracle: PostSolve only fills placeholder TVars; it never changes already-structured solver types.
tests: compiler/tests/Compiler/Type/PostSolve/PostSolveNonRegressionInvariantsTest.elm
--
--
name: PostSolve does not introduce new free type variables
phase: post-solve
invariants: POST_006
ir: Solver NodeTypes (pre-PostSolve) vs PostSolve NodeTypes (post-PostSolve)
logic:
  * Using the same nodeTypesPre/nodeTypesPost:
  * For each node id >= 0 that is neither VarKernel nor Accessor:
      - compute freeVars(preType) and freeVars(postType)
      - assert freeVars(postType) ⊆ freeVars(preType)
inputs: Canonical module + nodeTypesPre + nodeTypesPost
oracle: PostSolve cannot make a node more polymorphic than what the solver inferred.
tests: compiler/tests/Compiler/Type/PostSolve/PostSolveNonRegressionInvariantsTest.elm
--
```

### Step 3: Delete Old (Incorrect) Test Files

Remove the files created for the earlier approach:
- `compiler/tests/Compiler/Type/PostSolve/TVarScoping.elm`
- `compiler/tests/Compiler/Type/PostSolve/TVarScopingTest.elm`

### Step 4: Create New Invariant Checker Module

**File**: `compiler/tests/Compiler/Type/PostSolve/PostSolveNonRegressionInvariants.elm`

This module provides pure logic for:
- Node classification from canonical AST (`isVarKernel`, `isAccessor`)
- Alpha-equivalence: `alphaEq : Can.Type -> Can.Type -> Bool`
- Free variable extraction: `freeTypeVars : Can.Type -> Set String`
- Invariant checks:
  - `checkPost005 : Can.Module -> NodeTypesPre -> NodeTypesPost -> List Violation`
  - `checkPost006 : Can.Module -> NodeTypesPre -> NodeTypesPost -> List Violation`

Key data types:

```elm
type alias Violation =
    { invariant : String
    , nodeId : Int
    , kind : String
    , preType : Can.Type
    , postType : Can.Type
    , details : String
    }

type NodeKind
    = KVarKernel
    | KAccessor
    | KOther
```

### Step 5: Create Compile Helper for Pre/Post Snapshots

**File**: `compiler/tests/Compiler/Type/PostSolve/CompileThroughPostSolve.elm`

This helper runs the solver and PostSolve separately to capture both snapshots:

```elm
type alias Artifacts =
    { annotations : Dict String String Can.Annotation
    , nodeTypesPre : PostSolve.NodeTypes
    , nodeTypesPost : PostSolve.NodeTypes
    , kernelEnv : KernelTypes.KernelTypeEnv
    , canonical : Can.Module
    }

compileToPostSolve : Src.Module -> Result String Artifacts
```

This mirrors the production pipeline in `typeCheckTyped` but preserves the pre-PostSolve snapshot.

### Step 6: Create Test Suite

**File**: `compiler/tests/Compiler/Type/PostSolve/PostSolveNonRegressionInvariantsTest.elm`

Uses `StandardTestSuites.expectSuite` pattern:

```elm
suite : Test
suite =
    Test.describe "POST_005/POST_006: PostSolve Non-Regression"
        [ StandardTestSuites.expectSuite expectNonRegression "non-regression"
        ]

expectNonRegression : Src.Module -> Expectation
expectNonRegression srcModule =
    case compileToPostSolve srcModule of
        Err msg ->
            Expect.fail msg

        Ok artifacts ->
            let
                v5 = checkPost005 artifacts.canonical artifacts.nodeTypesPre artifacts.nodeTypesPost
                v6 = checkPost006 artifacts.canonical artifacts.nodeTypesPre artifacts.nodeTypesPost
            in
            case v5 ++ v6 of
                [] -> Expect.pass
                vs -> Expect.fail (formatViolations vs)
```

### Step 7: Update InvariantTests.elm

**File**: `compiler/tests/Compiler/InvariantTests.elm`

1. Remove the import for `TVarScopingTest`
2. Add import for `PostSolveNonRegressionInvariantsTest`
3. Replace the test in `postSolveInvariants`:

```elm
postSolveInvariants : Test
postSolveInvariants =
    Test.describe "Post-Solve Invariants"
        [ GroupBTypesTest.suite -- POST_001
        , KernelTypesTest.suite -- POST_002
        , NoSyntheticVarsTest.suite -- POST_003
        , DeterminismTest.suite -- POST_004
        , PostSolveNonRegressionInvariantsTest.suite -- POST_005, POST_006
        ]
```

## Algorithm Details

### Alpha-Equivalence

Two types are alpha-equivalent if they are structurally identical up to renaming of:
- Type variable names (`TVar "a"` ≡ `TVar "b"`)
- Record extension names

```elm
alphaEq : Can.Type -> Can.Type -> Bool
alphaEq a b =
    case (a, b) of
        (Can.TVar _, Can.TVar _) -> True  -- Any TVar matches any TVar
        (Can.TType h1 n1 as1, Can.TType h2 n2 as2) ->
            h1 == h2 && n1 == n2 && alphaEqList as1 as2
        (Can.TLambda a1 r1, Can.TLambda a2 r2) ->
            alphaEq a1 a2 && alphaEq r1 r2
        -- ... etc for other constructors
        _ -> False
```

### Free Type Variables

```elm
freeTypeVars : Can.Type -> Set String
freeTypeVars tipe =
    case tipe of
        Can.TVar v -> Set.singleton v
        Can.TType _ _ args -> List.foldl (\t acc -> Set.union acc (freeTypeVars t)) Set.empty args
        Can.TLambda a b -> Set.union (freeTypeVars a) (freeTypeVars b)
        -- ... etc
```

### Node Classification

Walk the canonical AST to build a map from node ID to kind:

```elm
collectExprKinds : Can.Module -> Dict Int NodeKind
collectExprKinds (Can.Module canData) =
    -- Traverse canData.decls, marking VarKernel and Accessor nodes
```

## Expected Behavior

### Tests That Should Pass

Most tests should pass because:
- If the solver produced a concrete type, PostSolve should preserve it
- If the solver produced a TVar placeholder, PostSolve may fill it (POST_005 allows this)
- Accessors and VarKernel are exempted from POST_006

### Tests That Should Fail (Real Bugs)

Tests with `[]` (empty list) where the solver inferred a concrete element type but PostSolve overwrote it with `List a`.

Example failure:
```
POST_006 violation at nodeId 5:
  preType:  TType (List) [TType (Int) []]
  postType: TType (List) [TVar "a"]
  details:  PostSolve introduced new free type vars: post ⊄ pre
```

## Files Summary

### New Files
1. `compiler/tests/Compiler/Type/PostSolve/PostSolveNonRegressionInvariants.elm`
2. `compiler/tests/Compiler/Type/PostSolve/CompileThroughPostSolve.elm`
3. `compiler/tests/Compiler/Type/PostSolve/PostSolveNonRegressionInvariantsTest.elm`

### Modified Files
1. `design_docs/invariants.csv` - Replace POST_005, POST_006 definitions
2. `design_docs/invariant-test-logic.md` - Replace POST_005, POST_006 blocks
3. `compiler/tests/Compiler/InvariantTests.elm` - Update imports and test registration

### Deleted Files
1. `compiler/tests/Compiler/Type/PostSolve/TVarScoping.elm`
2. `compiler/tests/Compiler/Type/PostSolve/TVarScopingTest.elm`

## Open Questions

### Q1: Access to Pre-PostSolve NodeTypes (RESOLVED)

The current `TOMono.runToPostSolve` already has access to both:
- `typedData.nodeTypes` - the pre-PostSolve types from `Solve.runWithIds`
- `postSolveResult.nodeTypes` - the post-PostSolve types

**Solution**: Create a new `runToPostSolveWithPre` function (or extend `PostSolveResult`) that returns both snapshots:

```elm
type alias PostSolveResultWithPre =
    { nodeTypesPre : PostSolve.NodeTypes   -- from solver
    , nodeTypesPost : PostSolve.NodeTypes  -- from PostSolve
    , kernelEnv : KernelTypes.KernelTypeEnv
    , canonical : Can.Module
    , annotations : Dict String Name.Name Can.Annotation
    }

runToPostSolveWithPre : Src.Module -> Result String PostSolveResultWithPre
runToPostSolveWithPre srcModule =
    -- Same as runToPostSolve but also returns typedData.nodeTypes as nodeTypesPre
```

The pipeline already separates these in the existing code at `compiler/tests/Compiler/Generate/TypedOptimizedMonomorphize.elm:392-395`.

### Q2: EverySet vs Set for Free Variables

The codebase uses `EverySet` (custom) vs standard `Set`. Need to use correct API.

**Resolution**: Use `EverySet` with `identity` comparator for String sets.

### Q3: Handling Missing Node IDs

If a node ID exists in pre but not post (or vice versa), how to handle?

**Suggested**:
- Missing in post: Report as POST_005 violation (PostSolve dropped the node)
- Missing in pre: Ignore (PostSolve added a new node - not a regression)

### Q4: Record Field Type Comparison

`Dict` keys for record fields use `A.Located Name` which requires `A.compareLocated`.

**Resolution**: Use `Dict.toList A.compareLocated` when comparing record types.

## Next Steps After Plan Approval

1. Delete the old TVarScoping files
2. Create the CompileThroughPostSolve helper
3. Create the PostSolveNonRegressionInvariants checker module
4. Create the test suite
5. Update InvariantTests.elm
6. Update documentation (invariants.csv, invariant-test-logic.md)
7. Run tests and report results
