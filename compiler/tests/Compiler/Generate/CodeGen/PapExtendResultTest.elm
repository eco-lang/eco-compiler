module Compiler.Generate.CodeGen.PapExtendResultTest exposing (suite)

{-| Tests for CGEN_034: PapExtend Result Type invariant.

`eco.papExtend` must produce `!eco.value` result.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( callExpr
        , intExpr
        , lambdaExpr
        , makeModule
        , pVar
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , findOpsNamed
        , getIntAttr
        , isEcoValueType
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_034: PapExtend Result Type"
        [ Test.test "eco.papExtend has exactly 1 result" singleResultTest
        , Test.test "eco.papExtend result is !eco.value" resultTypeTest
        , Test.test "eco.papExtend has remaining_arity attribute" remainingArityTest
        , Test.test "Closure application uses papExtend" closureApplicationTest
        ]



-- INVARIANT CHECKER


{-| Check papExtend result type invariants.
-}
checkPapExtendResult : MlirModule -> List Violation
checkPapExtendResult mlirModule =
    let
        papExtendOps =
            findOpsNamed "eco.papExtend" mlirModule

        violations =
            List.filterMap checkPapExtendOp papExtendOps
    in
    violations


checkPapExtendOp : MlirOp -> Maybe Violation
checkPapExtendOp op =
    let
        resultCount =
            List.length op.results

        maybeRemainingArity =
            getIntAttr "remaining_arity" op
    in
    if resultCount /= 1 then
        Just
            { opId = op.id
            , opName = op.name
            , message = "eco.papExtend should have exactly 1 result, got " ++ String.fromInt resultCount
            }

    else
        case List.head op.results of
            Nothing ->
                Nothing

            Just ( _, resultType ) ->
                if not (isEcoValueType resultType) then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message = "eco.papExtend result should be !eco.value, got " ++ typeToString resultType
                        }

                else
                    case maybeRemainingArity of
                        Nothing ->
                            Just
                                { opId = op.id
                                , opName = op.name
                                , message = "eco.papExtend missing remaining_arity attribute"
                                }

                        Just _ ->
                            Nothing


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
            name

        FunctionType _ ->
            "function"



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkPapExtendResult mlirModule)



-- TEST CASES


singleResultTest : () -> Expectation
singleResultTest _ =
    -- Higher-order function application
    let
        modul =
            makeModule "testValue"
                (callExpr
                    (callExpr (varExpr "List.map")
                        [ lambdaExpr [ pVar "x" ] (varExpr "x") ]
                    )
                    [ varExpr "[]" ]
                )
    in
    runInvariantTest modul


resultTypeTest : () -> Expectation
resultTypeTest _ =
    let
        modul =
            makeModule "testValue"
                (callExpr (varExpr "identity") [ intExpr 5 ])
    in
    runInvariantTest modul


remainingArityTest : () -> Expectation
remainingArityTest _ =
    let
        modul =
            makeModule "testValue"
                (callExpr
                    (lambdaExpr [ pVar "f", pVar "x" ] (callExpr (varExpr "f") [ varExpr "x" ]))
                    [ lambdaExpr [ pVar "y" ] (varExpr "y"), intExpr 42 ]
                )
    in
    runInvariantTest modul


closureApplicationTest : () -> Expectation
closureApplicationTest _ =
    -- Apply a closure
    let
        modul =
            makeModule "testValue"
                (callExpr
                    (lambdaExpr [ pVar "a" ] (varExpr "a"))
                    [ intExpr 100 ]
                )
    in
    runInvariantTest modul
