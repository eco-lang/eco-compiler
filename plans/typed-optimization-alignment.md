# Typed Optimization Alignment Plan

This plan aligns `Compiler.Optimize.Typed` with `Compiler.Optimize.Erased` to ensure algorithm parity and consistent naming conventions.

## Goals

1. Rename functions to match Erased naming conventions
2. Align exported API
3. Fix algorithm gaps (hasTailCall, LetRec special case)
4. Reorder parameters to preserve Erased signature pattern

---

## Wave 1: Function Renaming in Expression.elm

### 1.1 Rename `optimizeLocalDef` → `optimizeDef`

**File**: `src/Compiler/Optimize/Typed/Expression.elm`

**Current** (line 620):
```elm
optimizeLocalDef :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> ExprTypes
    -> Can.Def
    -> Can.Type
    -> TOpt.Expr
    -> Names.Tracker TOpt.Expr
optimizeLocalDef kernelEnv cycle annotations exprTypes def resultType body =
```

**Change to**:
```elm
optimizeDef :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> Can.Def
    -> Can.Type
    -> TOpt.Expr
    -> Names.Tracker TOpt.Expr
optimizeDef kernelEnv annotations exprTypes cycle def resultType body =
```

**Update all call sites** (approximately 5 occurrences):
- Line 224 in `Can.Let` case
- Line 239 in `Can.LetRec` case
- Line 520 in `optimizeTailExpr` Let case
- Line 525 in `optimizeTailExpr` LetRec case
- Any other references

### 1.2 Rename `optimizeLocalDefHelp` → `optimizeDefHelp`

**File**: `src/Compiler/Optimize/Typed/Expression.elm`

**Current** (line 638):
```elm
optimizeLocalDefHelp :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> ExprTypes
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> Can.Expr
    -> Can.Type
    -> TOpt.Expr
    -> Names.Tracker TOpt.Expr
optimizeLocalDefHelp kernelEnv cycle annotations exprTypes region name args expr resultType body =
```

**Change to**:
```elm
optimizeDefHelp :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> Can.Expr
    -> Can.Type
    -> TOpt.Expr
    -> Names.Tracker TOpt.Expr
optimizeDefHelp kernelEnv annotations exprTypes cycle region name args expr resultType body =
```

**Update call sites** in `optimizeDef` (2 occurrences).

---

## Wave 2: Export Alignment

### 2.1 Rename export from `optimizePotentialTailCallDef` to `optimizePotentialTailCall`

**File**: `src/Compiler/Optimize/Typed/Expression.elm`

**Current** (line 1-6):
```elm
module Compiler.Optimize.Typed.Expression exposing
    ( Cycle
    , optimize, optimizePotentialTailCallDef
    , destructArgs
    , buildFunctionType
    )
```

**Change to**:
```elm
module Compiler.Optimize.Typed.Expression exposing
    ( Cycle
    , optimize, optimizePotentialTailCall
    , destructArgs
    , buildFunctionType
    )
```

### 2.2 Rename `optimizePotentialTailCallDef` → `optimizePotentialTailCall`

**Current** (line 722):
```elm
optimizePotentialTailCallDef :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> ExprTypes
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> TCan.Expr
    -> Can.Type
    -> Names.Tracker TOpt.Def
optimizePotentialTailCallDef kernelEnv cycle annotations exprTypes region name args body defType =
```

**Change to** (with reordered parameters):
```elm
optimizePotentialTailCall :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> A.Region
    -> Name
    -> List Can.Pattern
    -> TCan.Expr
    -> Can.Type
    -> Names.Tracker TOpt.Def
optimizePotentialTailCall kernelEnv annotations exprTypes cycle region name args body defType =
```

### 2.3 Rename `optimizePotentialTailCallDefLocal` → `optimizePotentialTailCallDef`

**Current** (line 696):
```elm
optimizePotentialTailCallDefLocal :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> ExprTypes
    -> Can.Def
    -> Names.Tracker TOpt.Def
optimizePotentialTailCallDefLocal kernelEnv cycle annotations exprTypes def =
```

**Change to** (with reordered parameters):
```elm
optimizePotentialTailCallDef :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> Can.Def
    -> Names.Tracker TOpt.Def
optimizePotentialTailCallDef kernelEnv annotations exprTypes cycle def =
```

**Update call sites**:
- Line 229 in `Can.LetRec` case
- Line 710, 713 where it calls `optimizePotentialTailCall`

---

## Wave 3: Parameter Reordering

The goal is to preserve the Erased signature pattern where the last parameters match:
- Erased: `Cycle -> Can.Expr -> Names.Tracker Opt.Expr`
- Typed: `... -> Cycle -> TCan.Expr -> Names.Tracker TOpt.Expr`

New typed-specific parameters go at the start: `KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes`

### 3.1 Reorder `optimize` parameters

**Current** (line 63):
```elm
optimize : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> ExprTypes -> TCan.Expr -> Names.Tracker TOpt.Expr
optimize kernelEnv cycle annotations exprTypes (A.At region texpr) =
```

**Change to**:
```elm
optimize : KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> Cycle -> TCan.Expr -> Names.Tracker TOpt.Expr
optimize kernelEnv annotations exprTypes cycle (A.At region texpr) =
```

### 3.2 Reorder `optimizeExpr` parameters

**Current** (line 70):
```elm
optimizeExpr : KernelTypes.KernelTypeEnv -> Cycle -> Annotations -> ExprTypes -> A.Region -> Can.Type -> Can.Expr_ -> Names.Tracker TOpt.Expr
optimizeExpr kernelEnv cycle annotations exprTypes region tipe expr =
```

**Change to**:
```elm
optimizeExpr : KernelTypes.KernelTypeEnv -> Annotations -> ExprTypes -> Cycle -> A.Region -> Can.Type -> Can.Expr_ -> Names.Tracker TOpt.Expr
optimizeExpr kernelEnv annotations exprTypes cycle region tipe expr =
```

### 3.3 Reorder `optimizeTail` parameters

**Current** (line 437):
```elm
optimizeTail :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> ExprTypes
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> Can.Type
    -> TCan.Expr
    -> Names.Tracker TOpt.Expr
optimizeTail kernelEnv cycle annotations exprTypes rootName argNames resultType (A.At region texpr) =
```

**Change to**:
```elm
optimizeTail :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> Can.Type
    -> TCan.Expr
    -> Names.Tracker TOpt.Expr
optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (A.At region texpr) =
```

### 3.4 Reorder `optimizeTailExpr` parameters

**Current** (line 453):
```elm
optimizeTailExpr :
    KernelTypes.KernelTypeEnv
    -> Cycle
    -> Annotations
    -> ExprTypes
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> Can.Type
    -> A.Region
    -> Can.Type
    -> Can.Expr_
    -> Names.Tracker TOpt.Expr
optimizeTailExpr kernelEnv cycle annotations exprTypes rootName argNames resultType region tipe expr =
```

**Change to**:
```elm
optimizeTailExpr :
    KernelTypes.KernelTypeEnv
    -> Annotations
    -> ExprTypes
    -> Cycle
    -> Name
    -> List ( A.Located Name, Can.Type )
    -> Can.Type
    -> A.Region
    -> Can.Type
    -> Can.Expr_
    -> Names.Tracker TOpt.Expr
optimizeTailExpr kernelEnv annotations exprTypes cycle rootName argNames resultType region tipe expr =
```

### 3.5 Update all recursive calls

Every recursive call to these functions must be updated to pass parameters in the new order. This includes:
- All calls to `optimize` within `optimizeExpr`
- All calls to `optimizeTail` within `optimizeTailExpr`
- All calls between these functions

---

## Wave 4: Algorithm Fixes

### 4.1 Add `decidecHasTailCall` function

**File**: `src/Compiler/Optimize/Typed/Expression.elm`

Add after `hasTailCall` (around line 793):

```elm
{-| Check if a decider contains a tail call to the given function.
This is needed to detect tail calls in inlined Case branches.
-}
decidecHasTailCall : Name -> TOpt.Decider TOpt.Choice -> Bool
decidecHasTailCall funcName decider =
    case decider of
        TOpt.Leaf choice ->
            case choice of
                TOpt.Inline expr ->
                    hasTailCall funcName expr

                TOpt.Jump _ ->
                    False

        TOpt.Chain _ success failure ->
            decidecHasTailCall funcName success || decidecHasTailCall funcName failure

        TOpt.FanOut _ tests fallback ->
            decidecHasTailCall funcName fallback || List.any (Tuple.second >> decidecHasTailCall funcName) tests
```

### 4.2 Update `hasTailCall` to use `decidecHasTailCall`

**Current** (line 788):
```elm
TOpt.Case _ _ _ jumps _ ->
    List.any (\( _, branch ) -> hasTailCall funcName branch) jumps
```

**Change to**:
```elm
TOpt.Case _ _ decider jumps _ ->
    decidecHasTailCall funcName decider || List.any (\( _, branch ) -> hasTailCall funcName branch) jumps
```

### 4.3 Add single-def LetRec special case in `optimizeTailExpr`

**Current** (line 522-528):
```elm
Can.LetRec defs body ->
    List.foldl
        (\def bod ->
            Names.andThen (optimizeDef kernelEnv annotations exprTypes cycle def tipe) bod
        )
        (optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body))
        defs
```

**Change to**:
```elm
Can.LetRec defs body ->
    case defs of
        [ def ] ->
            optimizePotentialTailCallDef kernelEnv annotations exprTypes cycle def
                |> Names.andThen
                    (\tailCallDef ->
                        optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body)
                            |> Names.map (\obody -> TOpt.Let tailCallDef obody tipe)
                    )

        _ ->
            List.foldl
                (\def bod ->
                    Names.andThen (optimizeDef kernelEnv annotations exprTypes cycle def tipe) bod
                )
                (optimizeTail kernelEnv annotations exprTypes cycle rootName argNames resultType (TCan.toTypedExpr exprTypes body))
                defs
```

---

## Wave 5: Module.elm Updates

### 5.1 Update calls to renamed/reordered Expression functions

**File**: `src/Compiler/Optimize/Typed/Module.elm`

Update all calls to:
- `Expr.optimize` - new parameter order
- `Expr.optimizePotentialTailCall` - renamed from `optimizePotentialTailCallDef`, new parameter order
- `Expr.destructArgs` - unchanged

Locations to update:
- `addDefNode` (lines 558-596)
- `addRecDef` (lines 703-744)

### 5.2 Remove duplicate helpers

**Current**: `peelFunctionType` and `wrapDestruct` are defined in both Expression.elm and Module.elm.

**Change**: Remove from Module.elm, import from Expression.elm.

Update Module.elm exports or add to Expression.elm exports if needed.

---

## Wave 6: Verification

### 6.1 Build verification
```bash
cd /work/compiler && npm run build
```

### 6.2 Test verification
```bash
cd /work/compiler && npm test
```

### 6.3 Manual review
- Verify all function signatures match the pattern
- Verify all call sites pass parameters in correct order
- Verify algorithm behavior matches Erased

---

## Summary of Changes

| Wave | Change | Files Affected |
|------|--------|----------------|
| 1 | Rename `optimizeLocalDef` → `optimizeDef` | Expression.elm |
| 1 | Rename `optimizeLocalDefHelp` → `optimizeDefHelp` | Expression.elm |
| 2 | Rename export `optimizePotentialTailCallDef` → `optimizePotentialTailCall` | Expression.elm |
| 2 | Rename `optimizePotentialTailCallDefLocal` → `optimizePotentialTailCallDef` | Expression.elm |
| 3 | Reorder parameters: `kernelEnv, annotations, exprTypes, cycle, ...` | Expression.elm |
| 4 | Add `decidecHasTailCall` function | Expression.elm |
| 4 | Update `hasTailCall` to check deciders | Expression.elm |
| 4 | Add single-def LetRec special case in `optimizeTailExpr` | Expression.elm |
| 5 | Update calls to renamed/reordered functions | Module.elm |
| 5 | Remove duplicate `peelFunctionType`, `wrapDestruct` | Module.elm |
