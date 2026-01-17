module Compiler.Generate.CodeGen.CustomProjectionTest exposing (suite)

{-| Tests for CGEN_024: Custom ADT Projection invariant.

Custom ADT field access must use `eco.project.custom` with valid field index.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( UnionDef
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , tType
        , tVar
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_024: Custom ADT Projection"
        [ Test.test "eco.project.custom has field_index attribute" fieldIndexAttrTest
        , Test.test "eco.project.custom field_index is non-negative" fieldIndexNonNegativeTest
        , Test.test "eco.project.custom has exactly 1 operand" operandCountTest
        , Test.test "eco.project.custom has exactly 1 result" resultCountTest
        , Test.test "Maybe Just extraction uses correct projection" maybeJustTest
        ]



-- INVARIANT CHECKER


{-| Check custom projection invariants.
-}
checkCustomProjection : MlirModule -> List Violation
checkCustomProjection mlirModule =
    let
        customProjectOps =
            findOpsNamed "eco.project.custom" mlirModule

        violations =
            List.filterMap checkCustomProjectOp customProjectOps
    in
    violations


checkCustomProjectOp : MlirOp -> Maybe Violation
checkCustomProjectOp op =
    let
        maybeFieldIndex =
            getIntAttr "field_index" op

        operandCount =
            List.length op.operands

        resultCount =
            List.length op.results
    in
    case maybeFieldIndex of
        Nothing ->
            Just
                { opId = op.id
                , opName = op.name
                , message = "eco.project.custom missing field_index attribute"
                }

        Just fieldIndex ->
            if fieldIndex < 0 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.custom field_index=" ++ String.fromInt fieldIndex ++ " is negative"
                    }

            else if operandCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.custom should have exactly 1 operand, got " ++ String.fromInt operandCount
                    }

            else if resultCount /= 1 then
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.project.custom should have exactly 1 result, got " ++ String.fromInt resultCount
                    }

            else
                Nothing



-- TEST HELPER


{-| Maybe union type for tests.
-}
maybeUnion : UnionDef
maybeUnion =
    { name = "Maybe"
    , args = [ "a" ]
    , ctors =
        [ { name = "Just", args = [ tVar "a" ] }
        , { name = "Nothing", args = [] }
        ]
    }


{-| Helper to create a module that includes the Maybe type.
-}
makeModuleWithMaybe : String -> Src.Expr -> Src.Module
makeModuleWithMaybe name expr =
    makeModuleWithTypedDefsUnionsAliases "Test"
        [ { name = name
          , args = []
          , tipe = tType "Int" []
          , body = expr
          }
        ]
        [ maybeUnion ]
        []


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkCustomProjection mlirModule)



-- TEST CASES


fieldIndexAttrTest : () -> Expectation
fieldIndexAttrTest _ =
    let
        modul =
            makeModuleWithMaybe "testValue"
                (caseExpr (callExpr (ctorExpr "Just") [ intExpr 5 ])
                    [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Nothing" [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


fieldIndexNonNegativeTest : () -> Expectation
fieldIndexNonNegativeTest _ =
    let
        modul =
            makeModuleWithMaybe "testValue"
                (caseExpr (callExpr (ctorExpr "Just") [ intExpr 42 ])
                    [ ( pCtor "Just" [ pVar "v" ], varExpr "v" )
                    , ( pCtor "Nothing" [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


operandCountTest : () -> Expectation
operandCountTest _ =
    let
        modul =
            makeModuleWithMaybe "testValue"
                (caseExpr (callExpr (ctorExpr "Just") [ intExpr 1 ])
                    [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Nothing" [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


resultCountTest : () -> Expectation
resultCountTest _ =
    let
        modul =
            makeModuleWithMaybe "testValue"
                (caseExpr (callExpr (ctorExpr "Just") [ intExpr 99 ])
                    [ ( pCtor "Just" [ pVar "value" ], varExpr "value" )
                    , ( pCtor "Nothing" [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul


maybeJustTest : () -> Expectation
maybeJustTest _ =
    let
        modul =
            makeModuleWithMaybe "testValue"
                (caseExpr (callExpr (ctorExpr "Just") [ intExpr 10 ])
                    [ ( pCtor "Just" [ pVar "x" ], varExpr "x" )
                    , ( pCtor "Nothing" [], intExpr 0 )
                    ]
                )
    in
    runInvariantTest modul
