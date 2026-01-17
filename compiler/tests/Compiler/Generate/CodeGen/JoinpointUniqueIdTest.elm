module Compiler.Generate.CodeGen.JoinpointUniqueIdTest exposing (suite)

{-| Tests for CGEN_031: Joinpoint ID Uniqueness invariant.

Within a single `func.func`, each `eco.joinpoint` id must be unique.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( caseExpr
        , define
        , ifExpr
        , intExpr
        , letExpr
        , makeModule
        , pCtor
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findFuncOps
        , getIntAttr
        , getStringAttr
        , violationsToExpectation
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..))
import OrderedDict
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_031: Joinpoint ID Uniqueness"
        [ Test.test "eco.joinpoint has id attribute" joinpointHasIdTest
        , Test.test "Joinpoint ids are unique within function" joinpointIdsUniqueTest
        , Test.test "Multiple joinpoints have distinct ids" multipleJoinpointsTest
        , Test.test "Nested cases generate unique joinpoint ids" nestedCasesTest
        ]



-- INVARIANT CHECKER


{-| Check joinpoint ID uniqueness invariants.
-}
checkJoinpointUniqueness : MlirModule -> List Violation
checkJoinpointUniqueness mlirModule =
    let
        funcOps =
            findFuncOps mlirModule

        violations =
            List.concatMap checkFunctionJoinpoints funcOps
    in
    violations


checkFunctionJoinpoints : MlirOp -> List Violation
checkFunctionJoinpoints funcOp =
    let
        funcName =
            getStringAttr "sym_name" funcOp |> Maybe.withDefault "unknown"

        joinpoints =
            findJoinpointsInOp funcOp

        ( violations, _ ) =
            List.foldl
                (\jp ( accViolations, seenIds ) ->
                    let
                        maybeId =
                            getIntAttr "id" jp
                    in
                    case maybeId of
                        Nothing ->
                            ( { opId = jp.id
                              , opName = jp.name
                              , message = "eco.joinpoint missing id attribute"
                              }
                                :: accViolations
                            , seenIds
                            )

                        Just id ->
                            case Dict.get id seenIds of
                                Just firstOpId ->
                                    ( { opId = jp.id
                                      , opName = jp.name
                                      , message =
                                            "Duplicate joinpoint id "
                                                ++ String.fromInt id
                                                ++ " in function "
                                                ++ funcName
                                                ++ ", first at "
                                                ++ firstOpId
                                      }
                                        :: accViolations
                                    , seenIds
                                    )

                                Nothing ->
                                    ( accViolations
                                    , Dict.insert id jp.id seenIds
                                    )
                )
                ( [], Dict.empty )
                joinpoints
    in
    violations


findJoinpointsInOp : MlirOp -> List MlirOp
findJoinpointsInOp op =
    let
        selfJoinpoints =
            if op.name == "eco.joinpoint" then
                [ op ]

            else
                []

        regionJoinpoints =
            List.concatMap findJoinpointsInRegion op.regions
    in
    selfJoinpoints ++ regionJoinpoints


findJoinpointsInRegion : MlirRegion -> List MlirOp
findJoinpointsInRegion (MlirRegion { entry, blocks }) =
    let
        entryJoinpoints =
            findJoinpointsInBlock entry

        allBlocks =
            OrderedDict.values blocks

        blockJoinpoints =
            List.concatMap findJoinpointsInBlock allBlocks
    in
    entryJoinpoints ++ blockJoinpoints


findJoinpointsInBlock : MlirBlock -> List MlirOp
findJoinpointsInBlock block =
    let
        bodyJoinpoints =
            List.concatMap findJoinpointsInOp block.body

        terminatorJoinpoints =
            findJoinpointsInOp block.terminator
    in
    bodyJoinpoints ++ terminatorJoinpoints



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkJoinpointUniqueness mlirModule)



-- TEST CASES


joinpointHasIdTest : () -> Expectation
joinpointHasIdTest _ =
    -- Joinpoints should have id attributes
    let
        modul =
            makeModule "testValue"
                (ifExpr (varExpr "True") (intExpr 1) (intExpr 1))
    in
    runInvariantTest modul


joinpointIdsUniqueTest : () -> Expectation
joinpointIdsUniqueTest _ =
    -- Two different joinpoints should have different ids
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "a" [] (ifExpr (varExpr "True") (intExpr 1) (intExpr 1))
                    , define "b" [] (ifExpr (varExpr "False") (intExpr 2) (intExpr 2))
                    ]
                    (varExpr "a")
                )
    in
    runInvariantTest modul


multipleJoinpointsTest : () -> Expectation
multipleJoinpointsTest _ =
    -- Multiple case expressions with shared joinpoints
    let
        modul =
            makeModule "testValue"
                (letExpr
                    [ define "x" [] (ifExpr (varExpr "True") (intExpr 1) (intExpr 1))
                    , define "y" [] (ifExpr (varExpr "False") (intExpr 2) (intExpr 2))
                    , define "z" [] (ifExpr (varExpr "True") (intExpr 3) (intExpr 3))
                    ]
                    (varExpr "x")
                )
    in
    runInvariantTest modul


nestedCasesTest : () -> Expectation
nestedCasesTest _ =
    -- Nested case expressions
    let
        modul =
            makeModule "testValue"
                (caseExpr (varExpr "True")
                    [ ( pCtor "True" []
                      , ifExpr (varExpr "False") (intExpr 1) (intExpr 1)
                      )
                    , ( pCtor "False" []
                      , ifExpr (varExpr "True") (intExpr 2) (intExpr 2)
                      )
                    ]
                )
    in
    runInvariantTest modul
