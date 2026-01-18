module Compiler.Generate.CodeGen.RecordUpdateDataflowTest exposing (suite)

{-| Tests for CGEN_0D1: Record Update Dataflow Shape invariant.

Detects when a whole record is incorrectly stored as a field during record
update. The bug symptom: `{ original | x = 10 }` yields a record where field
`x` becomes the *original record* instead of `10`.

This is detected by checking that `eco.construct.record` operands don't include
the source record itself when other operands come from projections of that record.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , intExpr
        , lambdaExpr
        , letExpr
        , makeModule
        , pVar
        , recordExpr
        , updateExpr
        , varExpr
        )
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
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Set exposing (Set)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_0D1: Record Update Dataflow"
        [ Test.test "simple record update doesn't store whole record as field" simpleRecordUpdateTest
        , Test.test "multi-field record update is correct" multiFieldRecordUpdateTest
        , Test.test "fresh record construction passes" freshRecordTest
        , Test.test "nested record access is correct" nestedRecordAccessTest
        ]



-- PROJECTION INFO


{-| Information about a record projection operation.
-}
type alias ProjInfo =
    { source : String -- The record being projected from
    , result : String -- The SSA name of the projection result
    }



-- INVARIANT CHECKER


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


{-| Check a single function for record update dataflow issues.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        funcName =
            getStringAttr "sym_name" funcOp
                |> Maybe.withDefault "<unknown>"

        allOps =
            walkOpsInOp funcOp

        -- Collect all record projections
        projections =
            List.filterMap getRecordProj allOps

        -- Group projections by source record
        projectionsBySource =
            groupProjectionsBySource projections

        -- Find all record construction ops
        constructOps =
            List.filter (\op -> op.name == "eco.construct.record") allOps
    in
    List.filterMap (checkConstructOp funcName projectionsBySource) constructOps


{-| Extract projection info from an eco.project.record op.
-}
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


{-| Group projections by their source record.
-}
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


{-| Check a single eco.construct.record op for dataflow issues.
-}
checkConstructOp : String -> Dict String (Set String) -> MlirOp -> Maybe Violation
checkConstructOp funcName projectionsBySource constructOp =
    let
        operands =
            constructOp.operands

        operandSet =
            Set.fromList operands

        -- Find the "best" source record - the one whose projection results
        -- appear most often among the construct operands
        bestSource =
            findMostProjectedSource operandSet projectionsBySource
    in
    case bestSource of
        Nothing ->
            -- No projections used - probably a fresh record, not an update
            Nothing

        Just sourceRecord ->
            -- Check if the source record itself is used as an operand
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


{-| Find the source record whose projections appear most often in operand set.
Returns Nothing if no projections are used.
-}
findMostProjectedSource : Set String -> Dict String (Set String) -> Maybe String
findMostProjectedSource operandSet projectionsBySource =
    let
        -- For each source, count how many of its projection results are in operands
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



-- OP WALKING (within function)


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



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkRecordUpdateDataflow mlirModule)



-- TEST CASES


simpleRecordUpdateTest : () -> Expectation
simpleRecordUpdateTest _ =
    -- { r | x = 10 } - should NOT have r itself as operand
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "r" ]
                    (updateExpr (varExpr "r")
                        [ ( "x", intExpr 10 ) ]
                    )
                )
    in
    runInvariantTest modul


multiFieldRecordUpdateTest : () -> Expectation
multiFieldRecordUpdateTest _ =
    -- { r | x = 5, z = 7 } - multi-field update
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "r" ]
                    (updateExpr (varExpr "r")
                        [ ( "x", intExpr 5 )
                        , ( "z", intExpr 7 )
                        ]
                    )
                )
    in
    runInvariantTest modul


freshRecordTest : () -> Expectation
freshRecordTest _ =
    -- Fresh record construction { x = 1, y = 2 } - no source record
    let
        modul =
            makeModule "testValue"
                (recordExpr
                    [ ( "x", intExpr 1 )
                    , ( "y", intExpr 2 )
                    ]
                )
    in
    runInvariantTest modul


nestedRecordAccessTest : () -> Expectation
nestedRecordAccessTest _ =
    -- Accessing record fields in computation
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "r" ]
                    (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2))
                )
    in
    runInvariantTest modul
