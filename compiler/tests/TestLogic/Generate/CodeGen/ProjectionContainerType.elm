module TestLogic.Generate.CodeGen.ProjectionContainerType exposing
    ( expectProjectionContainerType
    , checkProjectionContainerTypes
    )

{-| Test logic for CGEN_0E1: Projection Container Type invariant.

All projection operations (eco.project.record, eco.project.custom, etc.)
must have !eco.value as their container operand type. This prevents
segfaults from treating primitives as heap pointers.

The dangerous pattern is: project -> eco.unbox -> project
where eco.unbox produces a primitive that is incorrectly used as a container.

@docs expectProjectionContainerType, checkProjectionContainerTypes

-}

import Compiler.AST.Source as Src
import TestLogic.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import TestLogic.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , findFuncOps
        , isEcoValueType
        , violationsToExpectation
        , walkOpsInRegion
        )
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict


{-| Verify that projection container type invariants hold for a source module.
-}
expectProjectionContainerType : Src.Module -> Expectation
expectProjectionContainerType srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkProjectionContainerTypes mlirModule)


projectionOpNames : List String
projectionOpNames =
    [ "eco.project.record"
    , "eco.project.custom"
    , "eco.project.tuple2"
    , "eco.project.tuple3"
    , "eco.project.list_head"
    , "eco.project.list_tail"
    ]


isProjectionOp : MlirOp -> Bool
isProjectionOp op =
    List.member op.name projectionOpNames


{-| Check that all projection ops have eco.value as container type.

This checks each function separately with its own scoped TypeEnv.

-}
checkProjectionContainerTypes : MlirModule -> List Violation
checkProjectionContainerTypes mlirModule =
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

        projectionOps =
            List.filter isProjectionOp allOps
    in
    List.filterMap (checkProjectionOp typeEnv) projectionOps


checkProjectionOp : TypeEnv -> MlirOp -> Maybe Violation
checkProjectionOp typeEnv op =
    case op.operands of
        [ containerName ] ->
            case Dict.get containerName typeEnv of
                Nothing ->
                    Nothing

                Just containerType ->
                    if isEcoValueType containerType then
                        Nothing

                    else
                        Just
                            { opId = op.id
                            , opName = op.name
                            , message =
                                "projection container '"
                                    ++ containerName
                                    ++ "' is not eco.value, got "
                                    ++ typeToString containerType
                            }

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "projection op should have exactly 1 operand, has "
                        ++ String.fromInt (List.length op.operands)
                }


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
