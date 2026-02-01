module TestLogic.Generate.CodeGen.DestructorTypeProjection exposing
    ( expectDestructorTypeProjection
    , checkDestructorTypeProjection
    , countProjectionUnboxSequences
    )

{-| Test logic for CGEN_004: Destructor Type Projection invariant.

generateDestruct and generateMonoPath must always use the destructor MonoType
to determine the path target MLIR type, not the body result type. This ensures
destruct paths yield their natural type and do not spuriously unbox.

This module provides utilities for verifying destructor projection types.
The main test approach is to count "projection → unbox" sequences in
generated MLIR and verify that count matches expectations for specific
test cases.

A spurious unbox pattern occurs when:

1.  eco.project.custom yields !eco.value
2.  That result is immediately fed into eco.unbox to get a primitive (i64, f64, i16)
3.  The primitive is a heap-unboxable type, suggesting the projection should have
    yielded the primitive directly if the MonoType was correctly specialized

@docs expectDestructorTypeProjection, checkDestructorTypeProjection, countProjectionUnboxSequences

-}

import Compiler.AST.Source as Src
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , findFuncOps
        , isEcoValueType
        , isUnboxable
        , violationsToExpectation
        , walkOpsInRegion
        )
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict


{-| Verify that destructor type projection invariants hold for a source module.
-}
expectDestructorTypeProjection : Src.Module -> Expectation
expectDestructorTypeProjection srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkDestructorTypeProjection mlirModule)


{-| Check for spurious unboxing patterns in projection operations.

A spurious unbox is when eco.project.custom yields !eco.value but is
immediately followed by eco.unbox, suggesting the projection used the
wrong type (generic type variable instead of specialized concrete type).

-}
checkDestructorTypeProjection : MlirModule -> List Violation
checkDestructorTypeProjection mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        typeEnv =
            buildTypeEnvFromOp funcOp

        allOps =
            walkOpsInOp funcOp

        -- Build a map of SSA values to their defining ops
        definingOps =
            buildDefiningOpsMap allOps

        -- Find all eco.unbox operations
        unboxOps =
            List.filter (\op -> op.name == "eco.unbox") allOps
    in
    List.filterMap (checkForSpuriousUnbox typeEnv definingOps) unboxOps


{-| Build a map from SSA value names to their defining operations.
-}
buildDefiningOpsMap : List MlirOp -> Dict.Dict String MlirOp
buildDefiningOpsMap ops =
    List.foldl
        (\op acc ->
            List.foldl
                (\( name, _ ) inner -> Dict.insert name op inner)
                acc
                op.results
        )
        Dict.empty
        ops


{-| Check if an eco.unbox operation indicates a spurious unbox pattern.

A spurious unbox is detected when:

1.  The operand to eco.unbox comes from eco.project.custom
2.  The eco.unbox result is a heap-unboxable type (i64, f64, i16)
3.  This suggests the projection should have yielded the primitive directly

-}
checkForSpuriousUnbox : TypeEnv -> Dict.Dict String MlirOp -> MlirOp -> Maybe Violation
checkForSpuriousUnbox typeEnv definingOps unboxOp =
    case unboxOp.operands of
        [ operandName ] ->
            case unboxOp.results of
                [ ( _, resultType ) ] ->
                    -- Only check for heap-unboxable result types
                    if not (isUnboxable resultType) then
                        Nothing

                    else
                        -- Check if the operand comes from a projection
                        case Dict.get operandName definingOps of
                            Just projectOp ->
                                if isCustomProjection projectOp then
                                    Just
                                        { opId = projectOp.id
                                        , opName = projectOp.name
                                        , message =
                                            "CGEN_004 violation: eco.project.custom yields !eco.value "
                                                ++ "but result is immediately unboxed to "
                                                ++ typeToString resultType
                                                ++ ". The projection should have yielded "
                                                ++ typeToString resultType
                                                ++ " directly if MonoType was correctly specialized."
                                        }

                                else
                                    Nothing

                            Nothing ->
                                Nothing

                _ ->
                    Nothing

        _ ->
            Nothing


isCustomProjection : MlirOp -> Bool
isCustomProjection op =
    op.name == "eco.project.custom"


buildTypeEnvFromOp : MlirOp -> TypeEnv
buildTypeEnvFromOp op =
    let
        withResults =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                Dict.empty
                op.results

        withRegions =
            List.foldl collectFromRegion withResults op.regions
    in
    withRegions


collectFromRegion : MlirRegion -> TypeEnv -> TypeEnv
collectFromRegion (MlirRegion { entry, blocks }) env =
    let
        withEntryArgs =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                entry.args

        withEntryBody =
            collectFromOps entry.body withEntryArgs

        withEntryTerm =
            collectFromOp entry.terminator withEntryBody

        withBlocks =
            List.foldl collectFromBlock withEntryTerm (OrderedDict.values blocks)
    in
    withBlocks


collectFromBlock : MlirBlock -> TypeEnv -> TypeEnv
collectFromBlock block env =
    let
        withArgs =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                block.args

        withBody =
            collectFromOps block.body withArgs

        withTerm =
            collectFromOp block.terminator withBody
    in
    withTerm


collectFromOps : List MlirOp -> TypeEnv -> TypeEnv
collectFromOps ops env =
    List.foldl collectFromOp env ops


collectFromOp : MlirOp -> TypeEnv -> TypeEnv
collectFromOp op env =
    let
        withResults =
            List.foldl
                (\( name, t ) acc -> Dict.insert name t acc)
                env
                op.results

        withRegions =
            List.foldl collectFromRegion withResults op.regions
    in
    withRegions


walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegion op.regions


typeToString : MlirType -> String
typeToString t =
    case t of
        I1 ->
            "i1"

        I16 ->
            "i16"

        I32 ->
            "i32"

        I64 ->
            "i64"

        F64 ->
            "f64"

        NamedStruct name ->
            "!" ++ name

        FunctionType _ ->
            "function"


{-| Count the number of eco.project.custom → eco.unbox sequences that
produce heap-unboxable types (i64, f64, i16).

For test cases with known types (e.g., extracting Int from Maybe Int),
this count should be 0 if CGEN\_004 is correctly implemented.

-}
countProjectionUnboxSequences : MlirModule -> Int
countProjectionUnboxSequences mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.sum (List.map countInFunction funcOps)


countInFunction : MlirOp -> Int
countInFunction funcOp =
    let
        allOps =
            walkOpsInOp funcOp

        definingOps =
            buildDefiningOpsMap allOps

        unboxOps =
            List.filter (\op -> op.name == "eco.unbox") allOps
    in
    List.length (List.filter (isSpuriousUnbox definingOps) unboxOps)


isSpuriousUnbox : Dict.Dict String MlirOp -> MlirOp -> Bool
isSpuriousUnbox definingOps unboxOp =
    case unboxOp.operands of
        [ operandName ] ->
            case unboxOp.results of
                [ ( _, resultType ) ] ->
                    if not (isUnboxable resultType) then
                        False

                    else
                        case Dict.get operandName definingOps of
                            Just projectOp ->
                                isCustomProjection projectOp

                            Nothing ->
                                False

                _ ->
                    False

        _ ->
            False
