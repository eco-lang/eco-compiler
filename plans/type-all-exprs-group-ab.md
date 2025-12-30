# Implementation Plan: Group A / Group B Expression Type Tracking

## Overview

This plan implements the "Group A / Group B" design from `design_docs/type-all-exprs-rethink.md` to optimize how expression IDs are mapped to solver variables during constraint generation.

**Goal**: Remove the problematic pattern of allocating a generic `exprVar` at `noRank` for every expression, which can disturb rank-based generalization.

**Strategy**:
- **Group A**: Expressions that already have a natural "result variable" (e.g., `answerVar` for binops) - reuse that variable for the expression's type
- **Group B**: Expressions without a natural result variable - keep the current behavior of allocating an extra `exprVar` and adding `CEqual`

## Current State

In `Compiler/Type/Constrain/Expression.elm`, `constrainWithIdsProg` (lines 587-618) currently:

1. Unconditionally allocates `exprVar` via `Prog.opMkFlexVarS`
2. Records `exprId -> exprVar` in NodeIds
3. Calls `constrainNodeWithIdsProg` for the inner constraint
4. Adds `CEqual region category exprType expected` for all non-VarKernel expressions

This creates **two** variables for Group A expressions and an unnecessary `CEqual` constraint.

## Expression Classification

### Group A (Reuse Existing Result Variable)

| Expression | Current Variable | Location in Code |
|------------|------------------|------------------|
| `Can.Int` | `var` (flex number) | lines 748-753 |
| `Can.Negate` | `numberVar` | lines 761-780 |
| `Can.Binop` | `answerVar` | lines 923-973 |
| `Can.Call` | `resultVar` | lines 1218-1266 |
| `Can.If` (unannotated) | `branchVar` | lines 1040-1060 |
| `Can.Case` (unannotated) | `bodyVar` | lines 1100-1138 |
| `Can.Access` | `fieldVar` | lines 833-862 |
| `Can.Update` | `recordVar` | lines 1358-1420 |

### Group B (Need Synthetic exprVar)

| Expression | Reason |
|------------|--------|
| `Can.Str`, `Can.Chr`, `Can.Float`, `Can.Unit` | Fixed type, no var allocated |
| `Can.List` | Composite type `AppN list [...]` |
| `Can.Record` | Composite type `RecordN` |
| `Can.Tuple` | Composite type `TupleN` |
| `Can.Lambda` | Composite type `FunN` chain |
| `Can.Accessor` | Composite type `FunN recordType fieldType` |
| `Can.VarLocal`, `Can.VarTopLevel`, etc. | Type instantiated from environment |
| `Can.If` (FromAnnotation) | No branchVar allocated |
| `Can.Case` (FromAnnotation) | No bodyVar allocated |
| `Can.Let`, `Can.LetRec`, `Can.LetDestruct` | Type is that of the body |
| `Can.Shader` | Composite shader type |

### Special Case
| Expression | Behavior |
|------------|----------|
| `Can.VarKernel` | Returns `CTrue`, no type variable |

## Implementation Steps

### Step 1: Create Generic Path for Group B

Extract the current `constrainWithIdsProg` body into a new helper:

```elm
constrainGenericWithIdsProg :
    RigidTypeVar -> A.Region -> ExprInfo -> E.Expected Type -> ProgS ExprIdState Constraint
constrainGenericWithIdsProg rtv region info expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\exprVar ->
                let
                    exprId = info.id
                    exprType = VarN exprVar
                in
                Prog.opModifyS (NodeIds.recordNodeVar exprId exprVar)
                    |> Prog.andThenS
                        (\() ->
                            let
                                category = nodeToCategory info.node
                            in
                            constrainNodeWithIdsProg rtv region info.node expected
                                |> Prog.mapS
                                    (\con ->
                                        CAnd [ con, CEqual region category exprType expected ]
                                    )
                        )
            )
```

### Step 2: Refactor constrainWithIdsProg

Change `constrainWithIdsProg` to dispatch based on expression type:

```elm
constrainWithIdsProg : RigidTypeVar -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainWithIdsProg rtv (A.At region exprInfo) expected =
    case exprInfo.node of
        -- Group A: Use specialized helpers that record the natural result var
        Can.Int _ ->
            constrainIntWithIdsProg region exprInfo.id expected

        Can.Negate expr ->
            constrainNegateWithIdsProg rtv region exprInfo.id expr expected

        Can.Binop op _ _ annotation leftExpr rightExpr ->
            constrainBinopWithIdsProg rtv region exprInfo.id op annotation leftExpr rightExpr expected

        Can.Call func args ->
            constrainCallWithIdsProg rtv region exprInfo.id func args expected

        Can.If branches finally ->
            constrainIfWithIdsProg rtv region exprInfo.id branches finally expected

        Can.Case expr branches ->
            constrainCaseWithIdsProg rtv region exprInfo.id expr branches expected

        Can.Access expr (A.At accessRegion field) ->
            constrainAccessWithIdsProg rtv region exprInfo.id expr accessRegion field expected

        Can.Update expr fields ->
            constrainUpdateWithIdsProg rtv region exprInfo.id expr fields expected

        -- Special case: no constraint
        Can.VarKernel _ _ ->
            Prog.pureS CTrue

        -- Group B: Use generic path with extra exprVar
        _ ->
            constrainGenericWithIdsProg rtv region exprInfo expected
```

### Step 3: Create/Modify Group A Helpers

#### 3.1 constrainIntWithIdsProg (NEW)

```elm
constrainIntWithIdsProg : A.Region -> Int -> E.Expected Type -> ProgS ExprIdState Constraint
constrainIntWithIdsProg region exprId expected =
    Prog.opMkFlexNumberS
        |> Prog.andThenS
            (\var ->
                Prog.opModifyS (NodeIds.recordNodeVar exprId var)
                    |> Prog.mapS
                        (\() ->
                            Type.exists [ var ] (CEqual region E.Number (VarN var) expected)
                        )
            )
```

#### 3.2 constrainNegateWithIdsProg (NEW)

```elm
constrainNegateWithIdsProg :
    RigidTypeVar -> A.Region -> Int -> Can.Expr -> E.Expected Type -> ProgS ExprIdState Constraint
constrainNegateWithIdsProg rtv region exprId expr expected =
    Prog.opMkFlexNumberS
        |> Prog.andThenS
            (\numberVar ->
                let
                    numberType = VarN numberVar
                in
                Prog.opModifyS (NodeIds.recordNodeVar exprId numberVar)
                    |> Prog.andThenS
                        (\() ->
                            constrainWithIdsProg rtv expr (FromContext region Negate numberType)
                                |> Prog.mapS
                                    (\numberCon ->
                                        let
                                            negateCon = CEqual region E.Number numberType expected
                                        in
                                        Type.exists [ numberVar ] (CAnd [ numberCon, negateCon ])
                                    )
                        )
            )
```

#### 3.3 constrainBinopWithIdsProg (MODIFY)

Add `exprId : Int` parameter and record `answerVar`:

```elm
constrainBinopWithIdsProg :
    RigidTypeVar
    -> A.Region
    -> Int  -- exprId (NEW)
    -> Name.Name
    -> Can.Annotation
    -> Can.Expr
    -> Can.Expr
    -> E.Expected Type
    -> ProgS ExprIdState Constraint
constrainBinopWithIdsProg rtv region exprId op annotation leftExpr rightExpr expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\leftVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\rightVar ->
                            Prog.opMkFlexVarS
                                |> Prog.andThenS
                                    (\answerVar ->
                                        -- NEW: Record answerVar for this expression
                                        Prog.opModifyS (NodeIds.recordNodeVar exprId answerVar)
                                            |> Prog.andThenS
                                                (\() ->
                                                    -- ... rest of existing logic unchanged
                                                )
                                    )
                        )
            )
```

#### 3.4 constrainCallWithIdsProg (MODIFY)

Add `exprId : Int` parameter and record `resultVar`:

```elm
constrainCallWithIdsProg :
    RigidTypeVar
    -> A.Region
    -> Int  -- exprId (NEW)
    -> Can.Expr
    -> List Can.Expr
    -> E.Expected Type
    -> ProgS ExprIdState Constraint
constrainCallWithIdsProg rtv region exprId ((A.At funcRegion _) as func) args expected =
    -- ... existing setup ...
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\funcVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\resultVar ->
                            -- NEW: Record resultVar for this expression
                            Prog.opModifyS (NodeIds.recordNodeVar exprId resultVar)
                                |> Prog.andThenS
                                    (\() ->
                                        -- ... rest of existing logic unchanged
                                    )
                        )
            )
```

#### 3.5 constrainIfWithIdsProg (MODIFY)

Add `exprId : Int` parameter. Record `branchVar` only for unannotated case:

```elm
constrainIfWithIdsProg :
    RigidTypeVar
    -> A.Region
    -> Int  -- exprId (NEW)
    -> List ( Can.Expr, Can.Expr )
    -> Can.Expr
    -> E.Expected Type
    -> ProgS ExprIdState Constraint
constrainIfWithIdsProg rtv region exprId branches final expected =
    -- ... setup conditions ...
    case expected of
        FromAnnotation name arity _ tipe ->
            -- Annotated case: Group B behavior - no natural var
            -- Record a synthetic exprVar
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\exprVar ->
                        Prog.opModifyS (NodeIds.recordNodeVar exprId exprVar)
                            |> Prog.andThenS
                                (\() ->
                                    -- existing annotated branch logic
                                    -- PLUS: CAnd with CEqual exprVar expected
                                )
                    )

        _ ->
            -- Unannotated case: Group A behavior
            Prog.opMkFlexVarS
                |> Prog.andThenS
                    (\branchVar ->
                        -- NEW: Record branchVar for this expression
                        Prog.opModifyS (NodeIds.recordNodeVar exprId branchVar)
                            |> Prog.andThenS
                                (\() ->
                                    -- existing unannotated logic
                                )
                    )
```

#### 3.6 constrainCaseWithIdsProg (MODIFY)

Similar to If - add `exprId`, record `bodyVar` for unannotated, synthetic var for annotated.

#### 3.7 constrainAccessWithIdsProg (NEW)

Move the `Can.Access` logic from `constrainNodeWithIdsProg` to a new helper:

```elm
constrainAccessWithIdsProg :
    RigidTypeVar
    -> A.Region
    -> Int  -- exprId
    -> Can.Expr
    -> A.Region
    -> Name.Name
    -> E.Expected Type
    -> ProgS ExprIdState Constraint
constrainAccessWithIdsProg rtv region exprId expr accessRegion field expected =
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\extVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\fieldVar ->
                            -- NEW: Record fieldVar for this expression
                            Prog.opModifyS (NodeIds.recordNodeVar exprId fieldVar)
                                |> Prog.andThenS
                                    (\() ->
                                        let
                                            fieldType = VarN fieldVar
                                            recordType = RecordN (Dict.singleton identity field fieldType) (VarN extVar)
                                            context = RecordAccess (A.toRegion expr) (getAccessName expr) accessRegion field
                                        in
                                        constrainWithIdsProg rtv expr (FromContext region context recordType)
                                            |> Prog.mapS
                                                (\recordCon ->
                                                    Type.exists [ fieldVar, extVar ]
                                                        (CAnd [ recordCon, CEqual region (Access field) fieldType expected ])
                                                )
                                    )
                        )
            )
```

#### 3.8 constrainUpdateWithIdsProg (MODIFY)

Add `exprId : Int` parameter and record `recordVar`:

```elm
constrainUpdateWithIdsProg :
    RigidTypeVar
    -> A.Region
    -> Int  -- exprId (NEW)
    -> Can.Expr
    -> Dict String (A.Located Name.Name) Can.FieldUpdate
    -> Expected Type
    -> ProgS ExprIdState Constraint
constrainUpdateWithIdsProg rtv region exprId expr locatedFields expected =
    -- ... existing setup ...
    Prog.opMkFlexVarS
        |> Prog.andThenS
            (\extVar ->
                Prog.opMkFlexVarS
                    |> Prog.andThenS
                        (\recordVar ->
                            -- NEW: Record recordVar for this expression
                            Prog.opModifyS (NodeIds.recordNodeVar exprId recordVar)
                                |> Prog.andThenS
                                    (\() ->
                                        -- ... rest of existing logic unchanged
                                    )
                        )
            )
```

### Step 4: Update constrainNodeWithIdsProg

Remove the Group A cases from `constrainNodeWithIdsProg` since they're now handled by specialized helpers. The remaining cases are Group B and will be called via `constrainGenericWithIdsProg`.

For the Group B cases, `constrainNodeWithIdsProg` continues to return the constraint without recording IDs (the ID recording happens in `constrainGenericWithIdsProg`).

### Step 5: Clean Up

1. Remove the old generic `exprVar` allocation from the top of `constrainWithIdsProg`
2. Ensure all call sites pass `exprId` where needed
3. Remove redundant cases from `constrainNodeWithIdsProg` that are now in specialized helpers

## Files to Modify

| File | Changes |
|------|---------|
| `Compiler/Type/Constrain/Expression.elm` | Main refactoring - split constrainWithIdsProg, add specialized helpers |
| `Compiler/Type/Constrain/NodeIds.elm` | No changes needed |
| `Compiler/Type/Constrain/Module.elm` | No changes needed |
| `Compiler/Type/Constrain/Pattern.elm` | No changes needed |
| `Compiler/Type/Constrain/Program.elm` | No changes needed |

## Testing Strategy

1. **Unit Tests**: Verify constraints generated are equivalent to before (modulo the extra `CEqual`)

2. **Type Check Tests**: Run existing type check test suite to ensure no regressions:
   ```bash
   # Run compiler tests
   cd /work/compiler && npm test
   ```

3. **TypedCanonical Tests**: Verify that all expression IDs still get types:
   - All non-placeholder IDs should have entries in NodeVarMap
   - Types should be correct after solving

4. **Polymorphism Tests**: Test let/let-rec examples to verify no regressions in type generalization:
   ```elm
   -- Should still generalize correctly
   identity x = x
   result = (identity 1, identity "hello")
   ```

5. **Edge Cases**:
   - Nested expressions (if inside case, etc.)
   - Recursive definitions
   - Annotated vs unannotated branches

## Verification Checklist

- [ ] Group A helpers record their natural result var in NodeIds
- [ ] Group A helpers produce identical constraints to original (minus extra CEqual)
- [ ] Group B expressions still get synthetic exprVar
- [ ] All expression IDs end up in NodeVarMap
- [ ] Negative/placeholder IDs are skipped
- [ ] Rank-based generalization works correctly
- [ ] No type inference regressions

## Questions Resolved

1. **If/Case with annotations**: When `expected` is `FromAnnotation`, these expressions don't allocate `branchVar`/`bodyVar`, so they fall into Group B. The helper will allocate a synthetic var for the annotation case.

2. **Can.Accessor vs Can.Access**:
   - `Can.Accessor` (`.field`) returns `FunN recordType fieldType` - Group B (composite type)
   - `Can.Access` (`record.field`) has `fieldVar` equated to expected - Group A

3. **Float literals**: `Can.Float` returns `CEqual region Float Type.float expected` with no var - Group B

## Rollout

1. Implement changes in a feature branch
2. Run full test suite
3. Manual testing with sample Elm projects
4. Code review
5. Merge to master
