# Implementation Plan: PostSolve Phase for Expression Types and Kernel Types

## Overview

This plan implements a new `PostSolve` phase that runs after the type solver to:
1. Fix "missing" expression types for Group B expressions (currently unconstrained)
2. Compute kernel function types (`KernelTypeEnv`) in the same traversal
3. Move kernel type construction out of the typed optimizer

Based on the design in `/work/design_docs/type-post-solver.md`.

## Current State Analysis

### Typed Pipeline Flow (Compiler/Compile.elm:224-243)

```
1. constrainWithIds(canonical) → (Constraint, NodeVarMap)
2. runWithIds(constraint, nodeVars) → { annotations, nodeTypes }
3. fromCanonical(canonical, nodeTypes) → TypedCanonical Module
4. optimizeTyped(annotations, nodeTypes, tcanModule) → TypedOptimized LocalGraph
```

### Group A/B Classification (Compiler/Type/Constrain/Expression.elm:595-657)

**Group A expressions** (lines 598-621): Have natural result variables recorded in `NodeIds`
- `Int`, `Negate`, `Binop`, `Call`, `If`, `Case`, `Access`, `Update`
- These expressions record their "answer" variable (e.g., `answerVar` for binop, `resultVar` for call)

**Group B expressions** (line 632-634): Use generic path with synthetic `exprVar`
- All other expressions: `Str`, `Chr`, `Float`, `List`, `Lambda`, `Let`, `Record`, `Tuple`, etc.
- Current behavior: Allocates `exprVar`, records in `NodeIds`, but **no constraint is added**
- Result: These variables remain completely unconstrained after solving

**VarKernel** (lines 624-630): Allocates `exprVar`, returns `CTrue` - needs type from `kernelEnv`

### Kernel Type Construction (Compiler/Optimize/Typed/KernelTypes.elm)

Currently computed in `optimizeTyped` over **TypedCanonical** (`TCan.Decls`):
- Phase 1 (`fromDecls`): Seed from alias definitions
- Phase 2 (`inferFromUsage`): Infer from call sites

**Problem**: This happens *after* `TypedCanonical` is built, but we need kernel types to assign proper types to `VarKernel` expression nodes.

## Goal

Create a single `PostSolve` pass over **Canonical** AST that:
1. Takes `nodeTypes` from solver (with Group B entries unconstrained)
2. Fixes all Group B expression types structurally
3. Assigns `VarKernel` types using the kernel environment
4. Returns fixed `nodeTypes` AND `kernelEnv`

This runs **before** `TypedCanonical.fromCanonical`, so the typed AST gets correct types.

## Implementation Steps

### Step 1: Create `Compiler/Type/PostSolve.elm` (NEW FILE)

**Location**: `/work/compiler/src/Compiler/Type/PostSolve.elm`

```elm
module Compiler.Type.PostSolve exposing (postSolve)

import Compiler.AST.Canonical as Can
import Compiler.Data.Name as Name exposing (Name)
import Compiler.Elm.ModuleName as ModuleName
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
import Compiler.Reporting.Annotation as A
import Data.Map as Dict exposing (Dict)
import System.TypeCheck.IO as IO

type alias NodeTypes =
    Dict Int Int Can.Type

postSolve :
    Dict String Name Can.Annotation
    -> Can.Module
    -> NodeTypes
    ->
        { nodeTypes : NodeTypes
        , kernelEnv : KernelTypes.KernelTypeEnv
        }
```

### Step 2: Implement Alias Seeding Over Canonical Decls

Add `seedKernelAliases` function that mirrors `KernelTypes.fromDecls` but works over `Can.Decls`:

```elm
seedKernelAliases :
    Dict String Name Can.Annotation
    -> Can.Decls
    -> KernelTypes.KernelTypeEnv
seedKernelAliases annotations decls =
    -- Walk decls looking for zero-arg defs whose body is VarKernel
    -- For each: lookup annotation and insert into env
```

**Key patterns to match**:
```elm
Can.Def (A.At _ name) [] (A.At _ (Can.VarKernel home kernelName)) ->
    -- Lookup `name` in annotations, insert type for (home, kernelName)

Can.TypedDef (A.At _ name) _ [] (A.At _ (Can.VarKernel home kernelName)) resultType ->
    -- Use resultType directly
```

### Step 3: Implement Declaration Traversal

```elm
postSolveDecls :
    Dict String Name Can.Annotation
    -> Can.Decls
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
```

Walks `Declare`, `DeclareRec`, `SaveTheEnvironment` and calls `postSolveDef` for each definition.

### Step 4: Implement Expression Traversal (Core Logic)

```elm
postSolveExpr :
    Dict String Name Can.Annotation
    -> Can.Expr
    -> NodeTypes
    -> KernelTypes.KernelTypeEnv
    -> ( NodeTypes, KernelTypes.KernelTypeEnv )
```

For each expression, based on its node type:

#### Group A Expressions (Trust Solver's Type)
- `Int`, `Negate`, `Binop`, `Call`, `If`, `Case`, `Access`, `Update`
- Just recurse into children, don't modify `nodeTypes[exprId]`

#### Group B Expressions (Compute Type Structurally)

| Node | Type Construction |
|------|-------------------|
| `Str _` | `TType ModuleName.string Name.string []` |
| `Chr _` | `TType ModuleName.char Name.char []` |
| `Float _` | `TType ModuleName.basics Name.float []` |
| `Unit` | `TUnit` |
| `List elems` | `TType ModuleName.list Name.list [elemType]` |
| `Tuple a b cs` | `TTuple aType bType csTypes` |
| `Record fields` | `TRecord fieldTypes Nothing` |
| `Lambda args body` | `TLambda arg1Type (TLambda arg2Type ... bodyType)` |

For each, write the computed type to `nodeTypes` at `exprId`.

#### VarKernel Expressions
```elm
Can.VarKernel home name ->
    case KernelTypes.lookup home name kernelEnv of
        Just t ->
            -- Write t to nodeTypes for this exprId
        Nothing ->
            -- Fallback: use TVar or crash (design decision)
```

#### Call Expressions (Kernel Type Inference)
When the callee is `VarKernel`:
1. Compute function type from arg types and result type
2. Call `KernelTypes.insertFirstUsage` to record it

### Step 5: Wire PostSolve Into Pipeline

**File**: `Compiler/Compile.elm`

Modify `typeCheckTyped` (lines 224-243):

```elm
typeCheckTyped modul canonical =
    let
        ioResult = ...  -- existing constraint/solve code
    in
    case ioResult of
        Err errors ->
            Err ...

        Ok { annotations, nodeTypes } ->
            let
                -- NEW: Run PostSolve before building TypedCanonical
                { nodeTypes = fixedNodeTypes, kernelEnv } =
                    PostSolve.postSolve annotations canonical nodeTypes

                typedCanonical =
                    TCan.fromCanonical canonical fixedNodeTypes
            in
            Ok
                { annotations = annotations
                , typedCanonical = typedCanonical
                , nodeTypes = fixedNodeTypes
                , kernelEnv = kernelEnv  -- NEW: Export kernelEnv
                }
```

Update the return type to include `kernelEnv`.

### Step 6: Update Typed Optimizer Signature

**File**: `Compiler/Optimize/Typed/Module.elm`

Change `optimizeTyped` to accept `kernelEnv` instead of computing it:

```elm
-- BEFORE:
optimizeTyped : Annotations -> ExprTypes -> TCan.Module -> MResult ...
optimizeTyped annotations exprTypes (TCan.Module tData) =
    let
        aliasEnv = KernelTypes.fromDecls annotations tData.decls
        kernelEnv = KernelTypes.inferFromUsage tData.decls exprTypes aliasEnv
    in
    ...

-- AFTER:
optimizeTyped : Annotations -> ExprTypes -> KernelTypes.KernelTypeEnv -> TCan.Module -> MResult ...
optimizeTyped annotations exprTypes kernelEnv (TCan.Module tData) =
    -- Remove aliasEnv/kernelEnv computation
    ...
```

### Step 7: Update Call Sites of `optimizeTyped`

**File**: `Compiler/Compile.elm`

Update `typedOptimizeFromTyped` (line 279-286) to pass `kernelEnv`.

### Step 8: Trim KernelTypes Module

**File**: `Compiler/Optimize/Typed/KernelTypes.elm`

Keep:
- `KernelTypeEnv` type
- `lookup`, `hasEntry`, `insertFirstUsage`, `buildFunctionType`

Remove or deprecate:
- `fromDecls` (moved to PostSolve)
- `inferFromUsage` (moved to PostSolve)

Update exports accordingly.

## Files to Modify

| File | Changes |
|------|---------|
| `Compiler/Type/PostSolve.elm` | **NEW FILE** - Main PostSolve implementation |
| `Compiler/Compile.elm` | Wire PostSolve into pipeline, update types |
| `Compiler/Optimize/Typed/Module.elm` | Accept kernelEnv as parameter |
| `Compiler/Optimize/Typed/KernelTypes.elm` | Remove fromDecls/inferFromUsage |

## Type Corrections from Design Doc

The design doc uses pseudocode. Actual types:

| Design Doc | Actual Code |
|------------|-------------|
| `Can.TApp ModuleName.list Name.list [t]` | `Can.TType ModuleName.list Name.list [t]` |
| `Can.Module canData` | `Can.Module (Can.ModuleData ...)` or pattern match directly |
| `Dict Int Int Can.Type` | Same - this is `TCan.NodeTypes` |

## Handling Edge Cases

### Lambda Argument Types

Patterns have IDs tracked via `Pattern.addWithIds`, which:
- Allocates a fresh `patVar` per pattern node
- Adds a `CPattern` constraint tying that var to the expected type
- Calls `NodeIds.recordNodeVar info.id patVar`

So `postSolveLambda` can work as follows:

```elm
postSolveLambda annotations exprId args body nodeTypes0 kernel0 =
    let
        -- First recurse into body
        ( nodeTypes1, kernel1 ) =
            postSolveExpr annotations body nodeTypes0 kernel0

        -- Get arg types from pattern IDs
        argTypes =
            List.map
                (\pat ->
                    case pat of
                        A.At _ info ->
                            Dict.get identity info.id nodeTypes1
                                |> Maybe.withDefault (Can.TVar "a")
                )
                args

        -- Get body type
        bodyType =
            case body of
                A.At _ info ->
                    Dict.get identity info.id nodeTypes1
                        |> Maybe.withDefault (Can.TVar "b")

        -- Build function type: arg1 -> arg2 -> ... -> bodyType
        funcType =
            List.foldr Can.TLambda bodyType argTypes

        nodeTypes2 =
            Dict.insert identity exprId funcType nodeTypes1
    in
    ( nodeTypes2, kernel1 )
```

**Alternative**: Treat Lambda as Group A and trust the solver's function type. In that case, only recurse into children without recomputing the function type. The pattern ID approach is more self-contained.

### Empty Lists

For Group B expressions, the synthetic `exprVar` is **never mentioned** in constraints - it's recorded but unconstrained. So `Type.toCanType` produces a bare `TVar`, not `List elemType`.

**Do NOT** try to "keep whatever the solver inferred" for empty lists.

Instead:
- **Non-empty lists**: Recurse into elements, get element type from first element, build `List elemType`
- **Empty lists**: Always write `List a` with a polymorphic type variable:

```elm
Can.TType ModuleName.list Name.list [ Can.TVar "a" ]
```

This matches the semantics (`[]` has type `List a` for some `a`) and is good enough for typed optimization - specialization decisions are driven by uses of this expression.

### Record Expressions

Recurse into field expressions first, then look up their types:

```elm
postSolveRecord annotations exprId fields nodeTypes0 kernel0 =
    let
        -- Recurse into all field expressions
        ( nodeTypes1, kernel1 ) =
            Dict.foldl
                (\_ fieldExpr ( nt, ke ) ->
                    postSolveExpr annotations fieldExpr nt ke
                )
                ( nodeTypes0, kernel0 )
                fields

        -- Build field type map
        fieldTypes =
            Dict.map
                (\_ fieldExpr ->
                    case fieldExpr of
                        A.At _ info ->
                            let
                                tipe =
                                    Dict.get identity info.id nodeTypes1
                                        |> Maybe.withDefault (Can.TVar "a")
                            in
                            Can.FieldType 0 tipe
                )
                fields

        recordType =
            Can.TRecord fieldTypes Nothing

        nodeTypes2 =
            Dict.insert identity exprId recordType nodeTypes1
    in
    ( nodeTypes2, kernel1 )
```

This works because field expressions are either Group A (already have meaningful types) or Group B (fixed by their own `postSolveExpr` cases during recursion).

### Annotated If/Case
When `expected` was `FromAnnotation`, these use Group B path (no `branchVar` allocated).
PostSolve should handle them like other Group B expressions.

### VarKernel Without Entry (Bare, Unaliased, Never-Called)

This is an **internal compiler invariant violation**, not a user error.

Every `VarKernel` that reaches typed optimization must have a type from either:
1. An alias annotation (seeded in phase 0), OR
2. At least one direct call usage (inferred in phase 1)

If neither exists (bare reference, no alias, no calls):

```elm
-- No alias for Elm.Kernel.List.map
myMap = Elm.Kernel.List.map  -- Unsupported!
```

**Behavior**: Crash via `Utils.Crash.crash` rather than fabricate a fake type.

**Rationale**:
- Assigning an arbitrary TVar or placeholder would cause monomorphization and type-directed transforms to work from nonsense
- Requiring either an annotated alias or a direct call is a clean, checkable invariant
- Matches the current `KernelTypes` spec and optimizer behavior

If softer failure is needed later, add a dedicated error type. For now, treat as internal bug.

## Testing Strategy

1. **Run existing test suite**: Ensure no regressions
   ```bash
   cd /work/compiler && npm test
   ```

2. **Verify all expression IDs have types**: After PostSolve, every non-placeholder ID should have an entry in `nodeTypes`

3. **Kernel type tests**: Verify alias-based and usage-based kernel types work correctly

4. **Group B type tests**: Verify strings, chars, floats, lists, tuples, records get correct types

## Verification Checklist

- [ ] PostSolve module created with correct structure
- [ ] Alias seeding works over Can.Decls
- [ ] Expression traversal covers all node types
- [ ] Group B types computed correctly:
  - [ ] Strings, Chars, Floats get correct primitive types
  - [ ] Lists: non-empty use element type, empty use `List a`
  - [ ] Records: build from field expression types
  - [ ] Tuples: build from component types
  - [ ] Lambdas: use pattern IDs for arg types, body ID for result
- [ ] VarKernel types assigned from kernelEnv (crash if missing)
- [ ] Kernel usage inference from Call nodes working
- [ ] Pipeline wired correctly in Compile.elm
- [ ] Typed optimizer accepts kernelEnv parameter
- [ ] KernelTypes module trimmed (fromDecls/inferFromUsage removed)
- [ ] All tests pass

## Design Decisions (Clarified)

1. **Why canonical instead of typed canonical?** PostSolve runs *before* TypedCanonical is built; it provides the fixed nodeTypes that TypedCanonical needs.

2. **Dict key for annotations?** The dict is `Dict String Name Can.Annotation`, keyed by `String`. Use `Dict.get identity name annotations`.

3. **Lambda arg types**: Use pattern IDs from `nodeTypes` - patterns have IDs recorded via `Pattern.addWithIds`.

4. **Empty lists**: Always write `List a` with polymorphic TVar. The solver's unconstrained synthetic var is not useful.

5. **VarKernel without entry**: Crash (internal invariant violation). Every VarKernel must have type from alias or direct call usage.

6. **Record expressions**: Recurse into field expressions first, then look up their types to build record type. Works because fields are fixed by their own postSolveExpr cases.
