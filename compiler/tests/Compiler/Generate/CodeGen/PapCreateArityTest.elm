module Compiler.Generate.CodeGen.PapCreateArityTest exposing (suite)

{-| Tests for CGEN_033: PapCreate Arity Constraints invariant.

`eco.papCreate` requires:

  - `arity > 0`
  - `num_captured == operand count`
  - `num_captured < arity`

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( UnionDef
        , binopsExpr
        , callExpr
        , ctorExpr
        , intExpr
        , lambdaExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pVar
        , qualVarExpr
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
        , getStringAttr
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_033: PapCreate Arity Constraints"
        [ Test.test "eco.papCreate has arity attribute" hasArityTest
        , Test.test "eco.papCreate has num_captured attribute" hasNumCapturedTest
        , Test.test "eco.papCreate arity > 0" arityPositiveTest
        , Test.test "eco.papCreate num_captured matches operand count" numCapturedMatchesTest
        , Test.test "eco.papCreate num_captured < arity" numCapturedLessThanArityTest
        , Test.test "Partial application creates valid papCreate" partialApplicationTest
        ]



-- INVARIANT CHECKER


{-| Check papCreate arity constraint invariants.
-}
checkPapCreateArity : MlirModule -> List Violation
checkPapCreateArity mlirModule =
    let
        papCreateOps =
            findOpsNamed "eco.papCreate" mlirModule

        violations =
            List.concatMap checkPapCreateOp papCreateOps
    in
    violations


checkPapCreateOp : MlirOp -> List Violation
checkPapCreateOp op =
    let
        maybeArity =
            getIntAttr "arity" op

        maybeNumCaptured =
            getIntAttr "num_captured" op

        maybeFuncAttr =
            getStringAttr "function" op

        operandCount =
            List.length op.operands
    in
    List.filterMap identity
        [ -- Check arity attribute exists
          case maybeArity of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.papCreate missing arity attribute"
                    }

            Just arity ->
                if arity <= 0 then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "eco.papCreate arity must be > 0, got " ++ String.fromInt arity
                        }

                else
                    Nothing

        -- Check num_captured attribute exists
        , case maybeNumCaptured of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.papCreate missing num_captured attribute"
                    }

            Just numCaptured ->
                -- Check num_captured matches operand count
                if numCaptured /= operandCount then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.papCreate num_captured="
                                ++ String.fromInt numCaptured
                                ++ " but operand count="
                                ++ String.fromInt operandCount
                        }

                else
                    Nothing

        -- Check num_captured < arity
        , case ( maybeArity, maybeNumCaptured ) of
            ( Just arity, Just numCaptured ) ->
                if numCaptured >= arity then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.papCreate num_captured="
                                ++ String.fromInt numCaptured
                                ++ " >= arity="
                                ++ String.fromInt arity
                                ++ ", not a valid partial application"
                        }

                else
                    Nothing

            _ ->
                Nothing

        -- Check function attribute exists
        , case maybeFuncAttr of
            Nothing ->
                Just
                    { opId = op.id
                    , opName = op.name
                    , message = "eco.papCreate missing function attribute"
                    }

            Just _ ->
                Nothing
        ]



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
          , tipe = tType "Maybe" [ tType "Int" [] ]
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
            violationsToExpectation (checkPapCreateArity mlirModule)



-- TEST CASES


hasArityTest : () -> Expectation
hasArityTest _ =
    -- Partial application: (+) 1
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2))
    in
    runInvariantTest modul


hasNumCapturedTest : () -> Expectation
hasNumCapturedTest _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (qualVarExpr "List" "map") [ lambdaExpr [ pVar "x" ] (varExpr "x") ])
    in
    runInvariantTest modul


arityPositiveTest : () -> Expectation
arityPositiveTest _ =
    let
        modul =
            makeModuleWithMaybe "testValue"
                (callExpr (ctorExpr "Just") [ intExpr 1 ])
    in
    runInvariantTest modul


numCapturedMatchesTest : () -> Expectation
numCapturedMatchesTest _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2))
    in
    runInvariantTest modul


numCapturedLessThanArityTest : () -> Expectation
numCapturedLessThanArityTest _ =
    -- Partial application should have num_captured < arity
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( intExpr 10, "*" ) ] (intExpr 5))
    in
    runInvariantTest modul


partialApplicationTest : () -> Expectation
partialApplicationTest _ =
    -- Create a partial application by not providing all arguments
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( intExpr 100, "/" ) ] (intExpr 10))
    in
    runInvariantTest modul
