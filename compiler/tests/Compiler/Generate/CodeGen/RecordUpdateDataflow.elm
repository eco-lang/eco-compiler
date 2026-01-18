module Compiler.Generate.CodeGen.RecordUpdateDataflow exposing
    ( expectRecordUpdateDataflow
    , checkRecordUpdateDataflow
    )

{-| Test logic for CGEN_0D1: Record Update Dataflow Shape invariant.

Detects when a whole record is incorrectly stored as a field during record
update. The bug symptom: `{ original | x = 10 }` yields a record where field
`x` becomes the *original record* instead of `10`.

This is detected by checking that `eco.construct.record` operands don't include
the source record itself when other operands come from projections of that record.

@docs expectRecordUpdateDataflow, checkRecordUpdateDataflow

-}

import Compiler.AST.Source as Src
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getStringAttr
        , violationsToExpectation
        , walkOpsInRegion
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import Set exposing (Set)


{-| Verify that record update dataflow invariants hold for a source module.
-}
expectRecordUpdateDataflow : Src.Module -> Expectation
expectRecordUpdateDataflow srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkRecordUpdateDataflow mlirModule)


{-| Information about a record projection operation.
-}
type alias ProjInfo =
    { source : String
    , result : String
    }


{-| Check that record updates don't store whole record as field.

This checks each function separately.

-}
checkRecordUpdateDataflow : MlirModule -> List Violation
checkRecordUpdateDataflow mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        funcName =
            getStringAttr "sym_name" funcOp
                |> Maybe.withDefault "<unknown>"

        allOps =
            walkOpsInOp funcOp

        projections =
            List.filterMap getRecordProj allOps

        projectionsBySource =
            groupProjectionsBySource projections

        constructOps =
            List.filter (\op -> op.name == "eco.construct.record") allOps
    in
    List.filterMap (checkConstructOp funcName projectionsBySource) constructOps


getRecordProj : MlirOp -> Maybe ProjInfo
getRecordProj op =
    if op.name /= "eco.project.record" then
        Nothing

    else
        case ( op.operands, op.results ) of
            ( [ src ], [ ( res, _ ) ] ) ->
                Just { source = src, result = res }

            _ ->
                Nothing


groupProjectionsBySource : List ProjInfo -> Dict String (Set String)
groupProjectionsBySource projections =
    List.foldl
        (\proj acc ->
            Dict.update proj.source
                (\maybeSet ->
                    case maybeSet of
                        Nothing ->
                            Just (Set.singleton proj.result)

                        Just set ->
                            Just (Set.insert proj.result set)
                )
                acc
        )
        Dict.empty
        projections


checkConstructOp : String -> Dict String (Set String) -> MlirOp -> Maybe Violation
checkConstructOp funcName projectionsBySource constructOp =
    let
        operands =
            constructOp.operands

        operandSet =
            Set.fromList operands

        bestSource =
            findMostProjectedSource operandSet projectionsBySource
    in
    case bestSource of
        Nothing ->
            Nothing

        Just sourceRecord ->
            if List.member sourceRecord operands then
                Just
                    { opId = constructOp.id
                    , opName = constructOp.name
                    , message =
                        "Record construction in function '"
                            ++ funcName
                            ++ "' stores whole record '"
                            ++ sourceRecord
                            ++ "' as a field. This is almost always a bug in record update codegen."
                    }

            else
                Nothing


findMostProjectedSource : Set String -> Dict String (Set String) -> Maybe String
findMostProjectedSource operandSet projectionsBySource =
    let
        sourceCounts =
            Dict.toList projectionsBySource
                |> List.map
                    (\( source, projResults ) ->
                        let
                            count =
                                Set.intersect projResults operandSet
                                    |> Set.size
                        in
                        ( source, count )
                    )
                |> List.filter (\( _, count ) -> count > 0)
                |> List.sortBy (\( _, count ) -> negate count)
    in
    case sourceCounts of
        ( source, _ ) :: _ ->
            Just source

        [] ->
            Nothing


walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegionLocal op.regions


walkOpsInRegionLocal : MlirRegion -> List MlirOp
walkOpsInRegionLocal (MlirRegion { entry, blocks }) =
    let
        entryOps =
            walkOpsInBlockLocal entry

        blockOps =
            List.concatMap walkOpsInBlockLocal (OrderedDict.values blocks)
    in
    entryOps ++ blockOps


walkOpsInBlockLocal : MlirBlock -> List MlirOp
walkOpsInBlockLocal block =
    let
        bodyOps =
            List.concatMap walkOp block.body

        termOps =
            walkOp block.terminator
    in
    bodyOps ++ termOps


walkOp : MlirOp -> List MlirOp
walkOp op =
    op :: List.concatMap walkOpsInRegionLocal op.regions
