module Compiler.Generate.CodeGen.KernelAbiConsistencyTest exposing (suite)

{-| Tests for CGEN_038: Kernel ABI Consistency invariant.

All calls to the same kernel function must use identical MLIR argument and
result types.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , floatExpr
        , intExpr
        , makeModule
        , strExpr
        , tuple3Expr
        , tupleExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , extractOperandTypes
        , extractResultTypes
        , findOpsNamed
        , getStringAttr
        , violationsToExpectation
        )
import Dict exposing (Dict)
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_038: Kernel ABI Consistency"
        [ Test.test "Multiple calls to same kernel use consistent types" sameKernelConsistentTest
        , Test.test "Int addition operations consistent" intAdditionConsistentTest
        , Test.test "String operations consistent" stringOpsConsistentTest
        , Test.test "Arithmetic operations consistent" arithmeticConsistentTest
        ]



-- INVARIANT CHECKER


{-| Check kernel ABI consistency invariants.
-}
checkKernelAbiConsistency : MlirModule -> List Violation
checkKernelAbiConsistency mlirModule =
    let
        callOps =
            findOpsNamed "eco.call" mlirModule

        -- Group calls by callee name
        callsByCallee =
            List.foldl groupCallByCallee Dict.empty callOps

        -- Check consistency within each group
        violations =
            Dict.foldl checkCalleeConsistency [] callsByCallee
    in
    violations


groupCallByCallee : MlirOp -> Dict String (List MlirOp) -> Dict String (List MlirOp)
groupCallByCallee op dict =
    case getStringAttr "callee" op of
        Nothing ->
            dict

        Just callee ->
            if isKernelFunction callee then
                Dict.update callee
                    (\maybeOps ->
                        case maybeOps of
                            Just ops ->
                                Just (op :: ops)

                            Nothing ->
                                Just [ op ]
                    )
                    dict

            else
                dict


isKernelFunction : String -> Bool
isKernelFunction name =
    String.startsWith "eco_" name
        || String.contains "$kernel$" name
        || String.startsWith "@eco_" name


checkCalleeConsistency : String -> List MlirOp -> List Violation -> List Violation
checkCalleeConsistency callee calls accViolations =
    case calls of
        [] ->
            accViolations

        [ _ ] ->
            -- Only one call, trivially consistent
            accViolations

        first :: rest ->
            let
                firstArgTypes =
                    extractOperandTypes first

                firstResultTypes =
                    extractResultTypes first

                newViolations =
                    List.filterMap (checkAgainstFirst callee first firstArgTypes firstResultTypes) rest
            in
            newViolations ++ accViolations


checkAgainstFirst : String -> MlirOp -> Maybe (List MlirType) -> List MlirType -> MlirOp -> Maybe Violation
checkAgainstFirst callee firstOp firstArgTypes firstResultTypes otherOp =
    let
        otherArgTypes =
            extractOperandTypes otherOp

        otherResultTypes =
            extractResultTypes otherOp
    in
    if firstArgTypes /= otherArgTypes then
        Just
            { opId = otherOp.id
            , opName = otherOp.name
            , message =
                "Kernel '"
                    ++ callee
                    ++ "' call has different arg types than previous call at "
                    ++ firstOp.id
            }

    else if firstResultTypes /= otherResultTypes then
        Just
            { opId = otherOp.id
            , opName = otherOp.name
            , message =
                "Kernel '"
                    ++ callee
                    ++ "' call has different result types than previous call at "
                    ++ firstOp.id
            }

    else
        Nothing



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkKernelAbiConsistency mlirModule)



-- TEST CASES


sameKernelConsistentTest : () -> Expectation
sameKernelConsistentTest _ =
    -- Multiple uses of same kernel
    let
        modul =
            makeModule "testValue"
                (tupleExpr
                    (binopsExpr [ ( intExpr 1, "+" ) ] (intExpr 2))
                    (binopsExpr [ ( intExpr 3, "+" ) ] (intExpr 4))
                )
    in
    runInvariantTest modul


intAdditionConsistentTest : () -> Expectation
intAdditionConsistentTest _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr
                    [ ( intExpr 1, "+" ), ( intExpr 2, "+" ) ]
                    (intExpr 3)
                )
    in
    runInvariantTest modul


stringOpsConsistentTest : () -> Expectation
stringOpsConsistentTest _ =
    let
        modul =
            makeModule "testValue"
                (binopsExpr [ ( strExpr "a", "++" ), ( strExpr "b", "++" ) ] (strExpr "c"))
    in
    runInvariantTest modul


arithmeticConsistentTest : () -> Expectation
arithmeticConsistentTest _ =
    let
        modul =
            makeModule "testValue"
                (tuple3Expr
                    (binopsExpr [ ( intExpr 10, "*" ) ] (intExpr 5))
                    (binopsExpr [ ( intExpr 20, "*" ) ] (intExpr 3))
                    (binopsExpr [ ( intExpr 100, "/" ) ] (intExpr 4))
                )
    in
    runInvariantTest modul
