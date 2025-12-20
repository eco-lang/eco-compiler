# Mini Kernel Solver Implementation Plan

## Overview

This plan implements a post-solver phase that deduces `VarKernel` types from their context, solving the problem that `VarKernel` expressions receive `CTrue` constraints (unconstrained) during type checking.

**Design document**: `/work/design_docs/mini-kernel-solver.md`

## Problem Statement

Currently, `VarKernel` expressions in the typed optimization path have meaningless types because:
- The constraint generator emits `CTrue` for `VarKernel` (no constraints)
- The solver assigns a fresh type variable that never gets constrained
- The resulting `Can.Type` in `TypedCanonical` is just an unconstrained `TVar`

This causes MLIR code generation to crash with "unresolved type variable" errors.

## Solution Summary

Implement a two-phase mini kernel solver:
1. **Phase 1 (existing)**: `fromDecls` - extracts types from annotated kernel aliases
2. **Phase 2 (new)**: `inferFromUsage` - infers types from direct call sites

The `VarKernel` case in `Expression.optimize` will then use `KernelTypes.lookup` instead of the unconstrained solver type.

**Note**: The design document has a minor type error in `inferDef` where it wraps `body` with `TCan.toTypedExpr`, but `body` in `TCan.Def` is already `TCan.Expr`. This plan corrects that by passing `body` directly to `inferExpr`.

---

## Implementation Steps

### Step 1: Add Helper Functions to KernelTypes.elm

**File**: `src/Compiler/Optimize/Typed/KernelTypes.elm`

Add to exposing list:
```elm
module Compiler.Optimize.Typed.KernelTypes exposing
    ( KernelTypeEnv
    , fromDecls
    , lookup           -- NEW
    , inferFromUsage   -- NEW
    )
```

Add helper functions:

```elm
-- Lookup a kernel type by (home, name)
lookup : Name -> Name -> KernelTypeEnv -> Maybe Can.Type
lookup home name env =
    Dict.get toComparable ( home, name ) env


-- Check if an entry exists
hasEntry : Name -> Name -> KernelTypeEnv -> Bool
hasEntry home name env =
    case Dict.get toComparable ( home, name ) env of
        Just _ -> True
        Nothing -> False


-- Insert only if no entry exists (first-usage-wins)
insertFirstUsage : Name -> Name -> Can.Type -> KernelTypeEnv -> KernelTypeEnv
insertFirstUsage home name tipe env =
    if hasEntry home name env then
        env
    else
        Dict.insert toComparable ( home, name ) tipe env


-- Build a function type from argument types and result type
buildFunctionType : List Can.Type -> Can.Type -> Can.Type
buildFunctionType argTypes resultType =
    List.foldr Can.TLambda resultType argTypes
```

### Step 2: Add Phase 2 - inferFromUsage

**File**: `src/Compiler/Optimize/Typed/KernelTypes.elm`

Add import:
```elm
import Compiler.AST.TypedCanonical as TCan exposing (ExprTypes)
```

Add the main function:

```elm
inferFromUsage : TCan.Decls -> ExprTypes -> KernelTypeEnv -> KernelTypeEnv
inferFromUsage decls exprTypes initialEnv =
    let
        inferDef : TCan.Def -> KernelTypeEnv -> KernelTypeEnv
        inferDef def env =
            case def of
                TCan.Def _ _ body ->
                    inferExpr body exprTypes env

                TCan.TypedDef _ _ _ body _ ->
                    inferExpr body exprTypes env

        inferDecls : TCan.Decls -> KernelTypeEnv -> KernelTypeEnv
        inferDecls ds env =
            case ds of
                TCan.Declare def rest ->
                    inferDecls rest (inferDef def env)

                TCan.DeclareRec d defs rest ->
                    let
                        env1 = inferDef d env
                        env2 = List.foldl inferDef env1 defs
                    in
                    inferDecls rest env2

                TCan.SaveTheEnvironment ->
                    env
    in
    inferDecls decls initialEnv
```

### Step 3: Add Expression Traversal

**File**: `src/Compiler/Optimize/Typed/KernelTypes.elm`

Add the expression traversal that finds kernel calls:

```elm
inferExpr : TCan.Expr -> ExprTypes -> KernelTypeEnv -> KernelTypeEnv
inferExpr (A.At _ texpr) exprTypes env =
    case texpr of
        TCan.TypedExpr { expr, tipe } ->
            case expr of
                -- Direct kernel call: Call (VarKernel home name) args
                Can.Call func args ->
                    let
                        typedFunc = TCan.toTypedExpr exprTypes func
                        envAfterFunc = inferExpr typedFunc exprTypes env
                        envAfterArgs =
                            List.foldl
                                (\arg acc -> inferExpr (TCan.toTypedExpr exprTypes arg) exprTypes acc)
                                envAfterFunc
                                args
                    in
                    case typedFunc of
                        A.At _ (TCan.TypedExpr { expr = Can.VarKernel home name }) ->
                            let
                                argTypes =
                                    List.map
                                        (\arg ->
                                            let
                                                A.At _ (TCan.TypedExpr { tipe = argType }) =
                                                    TCan.toTypedExpr exprTypes arg
                                            in
                                            argType
                                        )
                                        args

                                candidateType = buildFunctionType argTypes tipe
                            in
                            insertFirstUsage home name candidateType envAfterArgs

                        _ ->
                            envAfterArgs

                -- Recurse into all other expression forms...
                Can.Lambda _ body ->
                    inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env

                Can.If branches final ->
                    let
                        env1 =
                            List.foldl
                                (\( cond, thenExpr ) acc ->
                                    acc
                                        |> inferExpr (TCan.toTypedExpr exprTypes cond) exprTypes
                                        |> inferExpr (TCan.toTypedExpr exprTypes thenExpr) exprTypes
                                )
                                env
                                branches
                    in
                    inferExpr (TCan.toTypedExpr exprTypes final) exprTypes env1

                Can.Case scrutinee branches ->
                    let
                        env1 = inferExpr (TCan.toTypedExpr exprTypes scrutinee) exprTypes env
                        stepBranch (Can.CaseBranch _ branchExpr) acc =
                            inferExpr (TCan.toTypedExpr exprTypes branchExpr) exprTypes acc
                    in
                    List.foldl stepBranch env1 branches

                Can.Let def body ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env
                    in
                    inferDefExpr def exprTypes env1

                Can.LetRec defs body ->
                    let
                        env1 =
                            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env
                    in
                    List.foldl (\d acc -> inferDefExpr d exprTypes acc) env1 defs

                Can.LetDestruct _ bound body ->
                    inferExpr (TCan.toTypedExpr exprTypes bound) exprTypes env
                        |> inferExpr (TCan.toTypedExpr exprTypes body) exprTypes

                Can.List entries ->
                    List.foldl
                        (\e acc -> inferExpr (TCan.toTypedExpr exprTypes e) exprTypes acc)
                        env
                        entries

                Can.Negate sub ->
                    inferExpr (TCan.toTypedExpr exprTypes sub) exprTypes env

                Can.Binop _ _ _ _ left right ->
                    inferExpr (TCan.toTypedExpr exprTypes left) exprTypes env
                        |> inferExpr (TCan.toTypedExpr exprTypes right) exprTypes

                Can.Record fields ->
                    Dict.values A.compareLocated fields
                        |> List.foldl
                            (\fieldExpr acc -> inferExpr (TCan.toTypedExpr exprTypes fieldExpr) exprTypes acc)
                            env

                Can.Update record fields ->
                    let
                        env1 = inferExpr (TCan.toTypedExpr exprTypes record) exprTypes env
                    in
                    Dict.toList A.compareLocated fields
                        |> List.foldl
                            (\( _, Can.FieldUpdate _ e ) acc ->
                                inferExpr (TCan.toTypedExpr exprTypes e) exprTypes acc
                            )
                            env1

                Can.Accessor _ ->
                    env

                Can.Access record _ ->
                    inferExpr (TCan.toTypedExpr exprTypes record) exprTypes env

                Can.Tuple a b cs ->
                    inferExpr (TCan.toTypedExpr exprTypes a) exprTypes env
                        |> inferExpr (TCan.toTypedExpr exprTypes b) exprTypes
                        |> (\acc -> List.foldl (\e acc_ -> inferExpr (TCan.toTypedExpr exprTypes e) exprTypes acc_) acc cs)

                Can.Shader _ _ ->
                    env

                -- Leaves: no recursion needed
                Can.VarLocal _ -> env
                Can.VarTopLevel _ _ -> env
                Can.VarKernel _ _ -> env  -- bare kernel, cannot infer HO type
                Can.VarForeign _ _ _ -> env
                Can.VarCtor _ _ _ _ _ -> env
                Can.VarDebug _ _ _ -> env
                Can.VarOperator _ _ _ _ -> env
                Can.Chr _ -> env
                Can.Str _ -> env
                Can.Int _ -> env
                Can.Float _ -> env
                Can.Unit -> env


inferDefExpr : Can.Def -> ExprTypes -> KernelTypeEnv -> KernelTypeEnv
inferDefExpr def exprTypes env =
    case def of
        Can.Def _ _ body ->
            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env

        Can.TypedDef _ _ _ body _ ->
            inferExpr (TCan.toTypedExpr exprTypes body) exprTypes env
```

### Step 4: Update Module.optimizeTyped

**File**: `src/Compiler/Optimize/Typed/Module.elm`

Change the `kernelEnv` construction to include phase 2:

**Before**:
```elm
let
    kernelEnv : KernelTypes.KernelTypeEnv
    kernelEnv =
        KernelTypes.fromDecls annotations tData.decls
in
```

**After**:
```elm
let
    -- Phase 1: alias-based kernel types
    aliasEnv : KernelTypes.KernelTypeEnv
    aliasEnv =
        KernelTypes.fromDecls annotations tData.decls

    -- Phase 2: usage-based inference for unaliased kernels
    kernelEnv : KernelTypes.KernelTypeEnv
    kernelEnv =
        KernelTypes.inferFromUsage tData.decls exprTypes aliasEnv
in
```

### Step 5: Update Expression.optimizeExpr VarKernel Case

**File**: `src/Compiler/Optimize/Typed/Expression.elm`

Add imports (if not already present):
```elm
import Compiler.Data.Name as Name
import Compiler.Optimize.Typed.KernelTypes as KernelTypes
import Utils.Crash exposing (crash)
```

Change the `VarKernel` case:

**Before**:
```elm
Can.VarKernel home name ->
    Names.registerKernel home (TOpt.VarKernel region home name tipe)
```

**After**:
```elm
Can.VarKernel home name ->
    let
        kernelType : Can.Type
        kernelType =
            case KernelTypes.lookup home name kernelEnv of
                Just t ->
                    t

                Nothing ->
                    crash "Typed.Expression.optimizeExpr"
                        ("Missing kernel type for "
                            ++ Name.toChars home
                            ++ "."
                            ++ Name.toChars name
                        )
    in
    Names.registerKernel home (TOpt.VarKernel region home name kernelType)
```

---

## Testing

After implementation, run:
```bash
npx elm-test tests/Compiler/Optimize/OptimizeEquivalentTest.elm
npx elm-test tests/Compiler/Generate/TypedOptimizedMonomorphizeTest.elm
npx elm-test tests/Compiler/Generate/CodeGen/GenerateMLIRTest.elm
```

Expected improvements:
- MLIR tests should pass for more cases (kernel types now have real types)
- Optimization equivalence tests should continue passing

---

## Key Design Decisions

1. **Alias types are authoritative**: If a kernel has an annotated alias, we use that type and never check usage against it. This avoids polymorphic vs monomorphic comparison issues.

2. **First-usage-wins for unaliased kernels**: We take the first observed call site's types and don't validate subsequent uses. This avoids alpha-equivalence problems.

3. **Higher-order uses require aliases**: Kernels passed as arguments (not called) cannot have their types inferred. They must have annotated aliases.

4. **Crash on missing types**: If a kernel has no alias and no direct call usage, `lookup` returns `Nothing` and we crash. This is a compiler invariant violation, not a user error.

5. **Partial application handled correctly**: The call node's `tipe` is the post-application type, so `buildFunctionType argTypes tipe` correctly reconstructs the full function type.

---

## Files Modified

1. `src/Compiler/Optimize/Typed/KernelTypes.elm`
   - Add `lookup`, `hasEntry`, `insertFirstUsage`, `buildFunctionType`
   - Add `inferFromUsage`, `inferExpr`, `inferDefExpr`
   - Update exposing list

2. `src/Compiler/Optimize/Typed/Module.elm`
   - Update `optimizeTyped` to run both phases

3. `src/Compiler/Optimize/Typed/Expression.elm`
   - Update `VarKernel` case to use `KernelTypes.lookup`
   - Add import for `KernelTypes`
