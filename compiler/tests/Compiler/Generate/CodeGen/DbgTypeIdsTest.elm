module Compiler.Generate.CodeGen.DbgTypeIdsTest exposing (suite)

{-| Tests for CGEN_036: Dbg Type IDs Valid invariant.

When `eco.dbg` has `arg_type_ids`, each ID must reference a valid type table entry.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , intExpr
        , makeModule
        , strExpr
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getArrayAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirAttr(..), MlirModule, MlirOp)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_036: Dbg Type IDs Valid"
        [ Test.test "eco.dbg with type IDs references valid type table entries" dbgTypeIdsValidTest
        , Test.test "Type IDs are non-negative integers" typeIdsNonNegativeTest
        , Test.test "Module without debug ops passes" noDebugOpsTest
        ]



-- INVARIANT CHECKER


{-| Check dbg type IDs invariants.
-}
checkDbgTypeIds : MlirModule -> List Violation
checkDbgTypeIds mlirModule =
    let
        -- Find type table
        typeTableOps =
            List.filter (\op -> op.name == "eco.type_table") mlirModule.body

        maxTypeId =
            case List.head typeTableOps of
                Just typeTable ->
                    case getArrayAttr "types" typeTable of
                        Just types ->
                            List.length types - 1

                        Nothing ->
                            -1

                Nothing ->
                    -1

        -- Find all eco.dbg ops with arg_type_ids
        dbgOps =
            findOpsNamed "eco.dbg" mlirModule

        violations =
            List.concatMap (checkDbgOp maxTypeId) dbgOps
    in
    violations


checkDbgOp : Int -> MlirOp -> List Violation
checkDbgOp maxTypeId op =
    let
        maybeTypeIds =
            getArrayAttr "arg_type_ids" op
    in
    case maybeTypeIds of
        Nothing ->
            -- No type IDs, OK
            []

        Just typeIds ->
            if maxTypeId < 0 then
                [ { opId = op.id
                  , opName = op.name
                  , message = "eco.dbg has arg_type_ids but no eco.type_table in module"
                  }
                ]

            else
                List.indexedMap (checkTypeId op maxTypeId) typeIds
                    |> List.filterMap identity


checkTypeId : MlirOp -> Int -> Int -> MlirAttr -> Maybe Violation
checkTypeId op maxTypeId index attr =
    case attr of
        IntAttr _ typeId ->
            if typeId < 0 || typeId > maxTypeId then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message =
                        "eco.dbg arg_type_ids["
                            ++ String.fromInt index
                            ++ "]="
                            ++ String.fromInt typeId
                            ++ " out of range [0,"
                            ++ String.fromInt maxTypeId
                            ++ "]"
                    }

            else
                Nothing

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.dbg arg_type_ids[" ++ String.fromInt index ++ "] is not an integer"
                }



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkDbgTypeIds mlirModule)



-- TEST CASES


dbgTypeIdsValidTest : () -> Expectation
dbgTypeIdsValidTest _ =
    -- Debug.log usage
    let
        modul =
            makeModule "testValue"
                (callExpr (varExpr "Debug.log") [ strExpr "msg", intExpr 42 ])
    in
    runInvariantTest modul


typeIdsNonNegativeTest : () -> Expectation
typeIdsNonNegativeTest _ =
    -- Debug.toString usage
    let
        modul =
            makeModule "testValue"
                (callExpr (varExpr "Debug.toString") [ intExpr 123 ])
    in
    runInvariantTest modul


noDebugOpsTest : () -> Expectation
noDebugOpsTest _ =
    -- Simple module without debug
    runInvariantTest (makeModule "testValue" (intExpr 42))
