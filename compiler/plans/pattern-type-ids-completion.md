# Plan: Complete Pattern Type ID Implementation

## Overview

This plan addresses the gaps between the design in `design_docs/pattern-type-ids.md` and the current implementation. The goal is to establish a unified ID space for expressions and patterns, enabling pattern types to flow through the type checking pipeline.

## Current State

**Implemented:**
- `PatternInfo` with IDs in Canonical AST
- `Compiler.Canonicalize.Ids` module for shared ID allocation
- `Pattern.canonicalizeWithIds` function
- `Compiler.Type.Constrain.NodeIds` module
- `Pattern.addWithIds` function

**Not Implemented (Gaps):**
- Expression canonicalization doesn't call `Pattern.canonicalizeWithIds`
- Expression constraint generation doesn't use `NodeIdState`
- No `constrainArgsWithIds` helper
- Module/Solver/Compile not updated to unified API

---

## Step 1: Wire Pattern.canonicalizeWithIds into Expression Canonicalization

**Files:** `src/Compiler/Canonicalize/Expression.elm`

**Changes:**
1. Update Lambda canonicalization (around line 246-262) to:
   - Call `Pattern.canonicalizeWithIds` instead of `Pattern.canonicalize`
   - Thread `IdState` through all pattern args
   - Pass the resulting state to body canonicalization

2. Update Case branch canonicalization (around line 283-287) to:
   - Call `Pattern.canonicalizeWithIds` for branch patterns
   - Thread `IdState` through branches

3. Update Let definition pattern handling (around line 279-281) to:
   - Use `Pattern.canonicalizeWithIds` for destructuring patterns

4. Update other pattern usages at lines 372, 584, 638, 775

**Helper needed:**
```elm
traversePatternsWithIds :
    SyntaxVersion
    -> Env.Env
    -> IdState
    -> List Src.Pattern
    -> PResult DupsDict w ( List Can.Pattern, IdState )
```

---

## Step 2: Refactor Expression Constraint to Use NodeIdState

**Files:** `src/Compiler/Type/Constrain/Expression.elm`

**Changes:**
1. Remove local definitions (lines 1277-1292):
   - `ExprVarMap`
   - `ExprIdState`
   - `emptyExprIdState`

2. Add import and type aliases:
   ```elm
   import Compiler.Type.Constrain.NodeIds as NodeIds

   type alias ExprVarMap = NodeIds.NodeVarMap
   type alias ExprIdState = NodeIds.NodeIdState

   emptyExprIdState : ExprIdState
   emptyExprIdState = NodeIds.emptyNodeIdState
   ```

3. Update `constrainWithIds` to use `NodeIds.recordNodeVar`:
   ```elm
   newState = NodeIds.recordNodeVar exprId exprVar state
   ```

---

## Step 3: Add constrainArgsWithIds Helper

**Files:** `src/Compiler/Type/Constrain/Expression.elm`

**Changes:**
1. Add new function after `constrainArgs`:
   ```elm
   constrainArgsWithIds :
       List Can.Pattern
       -> NodeIds.NodeIdState
       -> IO ( Args, NodeIds.NodeIdState )
   ```

2. Add helper:
   ```elm
   argsHelpWithIds :
       List Can.Pattern
       -> Pattern.State
       -> NodeIds.NodeIdState
       -> IO ( Args, NodeIds.NodeIdState )
   ```

3. These functions call `Pattern.addWithIds` instead of `Pattern.add`

---

## Step 4: Update constrainDefWithIds to Use Pattern ID Tracking

**Files:** `src/Compiler/Type/Constrain/Expression.elm`

**Changes:**
1. Update `constrainDefWithIds` (line 1297-1361) to:
   - Call `constrainArgsWithIds` instead of `constrainArgs`
   - Thread `NodeIdState` through args and expression

2. Update `constrainRecursiveDefsWithIds` (line 1365-1460) similarly

3. Update `recDefsHelpWithIds` to thread `NodeIdState`

---

## Step 5: Add constrainTypedArgsWithIds

**Files:** `src/Compiler/Type/Constrain/Expression.elm`

**Changes:**
1. Add ID-aware version of `typedArgsHelp`:
   ```elm
   typedArgsHelpWithIds :
       RigidTypeVar
       -> Name.Name
       -> Index.ZeroBased
       -> List ( Can.Pattern, Can.Type )
       -> Can.Type
       -> Pattern.State
       -> NodeIds.NodeIdState
       -> IO ( TypedArgs, NodeIds.NodeIdState )
   ```

2. This version calls `Pattern.addWithIds` for typed patterns

---

## Step 6: Update Module Constraint Generation

**Files:** `src/Compiler/Type/Constrain/Module.elm`

**Changes:**
1. Add import:
   ```elm
   import Compiler.Type.Constrain.NodeIds as NodeIds
   ```

2. Add new function (keep old for compatibility):
   ```elm
   constrainWithIds : Can.Module -> IO ( Constraint, NodeIds.NodeVarMap )
   constrainWithIds (Can.Module canData) =
       let
           initialState = NodeIds.emptyNodeIdState
       in
       -- ... use initialState instead of Expr.emptyExprIdState
   ```

3. Update `constrainDeclsWithVars` to use `NodeIds.NodeIdState`

4. Update helper functions to thread `NodeIdState`

---

## Step 7: Generalize Solver API

**Files:** `src/Compiler/Type/Solve.elm`

**Changes:**
1. Update module exports:
   ```elm
   module Compiler.Type.Solve exposing (run, runWithExprVars, runWithIds)
   ```

2. Add new function:
   ```elm
   runWithIds :
       Constraint
       -> Dict Int Int Variable
       -> IO (Result (NE.Nonempty Error.Error)
           { annotations : Dict String Name.Name Can.Annotation
           , nodeTypes : Dict Int Int Can.Type
           })
   ```

3. Implement `runWithIds` (mostly copy of `runWithExprVars` with renamed field)

4. Optionally make `runWithExprVars` call `runWithIds` and rename field

---

## Step 8: Update Compile.elm

**Files:** `src/Compiler/Compile.elm`

**Changes:**
1. Update `typeCheckTyped` (around lines 227-240):
   ```elm
   typeCheckTyped modul canonical =
       let
           ioResult =
               Type.constrainWithIds canonical
                   |> TypeCheck.andThen
                       (\( constraint, nodeVars ) ->
                           Type.runWithIds constraint nodeVars
                       )
                   |> TypeCheck.unsafePerformIO
       in
       case ioResult of
           Err errors ->
               Err (E.BadTypes (Localizer.fromModule modul) errors)

           Ok { annotations, nodeTypes } ->
               let
                   typedCanonical =
                       TCan.fromCanonical canonical nodeTypes
               in
               Ok { annotations = annotations, typedCanonical = typedCanonical }
   ```

---

## Step 9: Update TypedCanonical (Optional Enhancement)

**Files:** `src/Compiler/AST/TypedCanonical.elm`

**Changes:**
1. Rename parameter from `exprTypes` to `nodeTypes` in `fromCanonical`
2. Update documentation to reflect unified node types
3. (Future) Add `TypedPattern` type and build typed patterns using pattern IDs

---

## Implementation Order

1. **Step 2** - Refactor Expression to use NodeIdState (low risk, enables later steps)
2. **Step 3** - Add constrainArgsWithIds (adds new code, no changes to existing)
3. **Step 5** - Add constrainTypedArgsWithIds (adds new code)
4. **Step 4** - Update constrainDefWithIds (switches to new helpers)
5. **Step 6** - Update Module constraint generation
6. **Step 7** - Generalize Solver API
7. **Step 8** - Update Compile.elm
8. **Step 1** - Wire Pattern.canonicalizeWithIds (most complex, affects canonicalization)
9. **Step 9** - Optional TypedCanonical updates

## Implementation Status

**Completed:**
- Step 2: ExprVarMap and ExprIdState are now aliases for NodeIds types ✓
- Step 3: Added constrainArgsWithIds and argsHelpWithIds ✓
- Step 4: Updated constrainDefWithIds and constrainRecursiveDefsWithIds ✓
- Step 5: Added constrainTypedArgsWithIds and typedArgsHelpWithIds ✓
- Step 6: Added constrainWithIds to Module.elm ✓
- Step 7: Added runWithIds to Solve.elm ✓
- Step 8: Updated Compile.elm to use constrainWithIds/runWithIds and NodeTypes ✓
- Step 9: Added NodeTypes type alias to TypedCanonical.elm ✓

**Partially Completed:**
- Step 1: Added infrastructure (Pattern.traverseWithIds, Pattern.verifyWithIds)
  but Expression.elm not yet updated to use unified ID space

**Remaining for Step 1:**
The `canonicalizeNode` function in Expression.elm needs refactoring to:
1. Thread IdState through Lambda argument patterns (use traverseWithIds)
2. Thread IdState through Case branch patterns
3. Thread IdState through Let definition patterns
4. Properly return final IdState from nested canonicalizations

This requires careful handling of the ReportingResult monad and the
`delayedUsage` wrapper used for free variable tracking.

## Testing Strategy

- Build after each step to catch type errors early
- Steps 2-7 can be done incrementally with build verification
- Step 1 and Step 8 are the "activation" steps that actually change behavior
- Final verification: pattern types should appear in nodeTypes dictionary

## Risks

- **Step 1** is complex due to ReportingResult monad threading
- **Step 4-5** changes to def constraint generation could affect type inference
- Need to ensure backwards compatibility for non-typed pipeline

## Estimated Scope

- Steps 2, 3, 5, 7, 9: Small changes (add/refactor types and functions)
- Steps 4, 6, 8: Medium changes (update existing functions)
- Step 1: Large change (significant refactor of expression canonicalization)
