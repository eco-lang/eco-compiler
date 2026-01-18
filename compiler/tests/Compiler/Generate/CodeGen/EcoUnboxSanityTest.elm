module Compiler.Generate.CodeGen.EcoUnboxSanityTest exposing (suite)

{-| Tests for CGEN_0E2: eco.unbox Sanity invariant.

eco.unbox converts !eco.value (boxed) to a primitive type (i1, i16, i64, f64).
This test verifies:

1.  The operand is !eco.value
2.  The result is a primitive type (i1, i16, i64, or f64)

Note: i32 is NOT a primitive in eco.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( binopsExpr
        , callExpr
        , caseExpr
        , chrExpr
        , floatExpr
        , ifExpr
        , intExpr
        , lambdaExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , pChr
        , pCtor
        , pVar
        , qualVarExpr
        , tLambda
        , tType
        , varExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( TypeEnv
        , Violation
        , findFuncOps
        , findOpsNamed
        , isEcoValueType
        , isPrimitiveType
        , violationsToExpectation
        , walkOpsInRegion
        )
import Dict
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirBlock, MlirModule, MlirOp, MlirRegion(..), MlirType(..))
import OrderedDict
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_0E2: eco.unbox Sanity"
        [ Test.test "eco.unbox converts eco.value to i64 for Int" intUnboxTest
        , Test.test "eco.unbox converts eco.value to f64 for Float" floatUnboxTest
        , Test.test "eco.unbox converts eco.value to i1 for Bool" boolUnboxTest
        , Test.test "eco.unbox converts eco.value to i16 for Char" charUnboxTest
        , Test.test "arithmetic operations use correct unboxing" arithmeticUnboxTest
        ]



-- INVARIANT CHECKER


{-| Check that all eco.unbox ops have correct types.

This checks each function separately with its own scoped TypeEnv.

-}
checkEcoUnboxSanity : MlirModule -> List Violation
checkEcoUnboxSanity mlirModule =
    let
        funcOps =
            findFuncOps mlirModule
    in
    List.concatMap checkFunction funcOps


{-| Check a single function.
-}
checkFunction : MlirOp -> List Violation
checkFunction funcOp =
    let
        typeEnv =
            buildTypeEnvFromOp funcOp

        allOps =
            walkOpsInOp funcOp

        unboxOps =
            List.filter (\op -> op.name == "eco.unbox") allOps
    in
    List.filterMap (checkUnboxOp typeEnv) unboxOps


{-| Check a single eco.unbox op.
-}
checkUnboxOp : TypeEnv -> MlirOp -> Maybe Violation
checkUnboxOp typeEnv op =
    -- Check operand count
    case op.operands of
        [ operandName ] ->
            -- Check result count
            case op.results of
                [ ( _, resultType ) ] ->
                    -- Check operand type is eco.value
                    case Dict.get operandName typeEnv of
                        Nothing ->
                            -- Can't verify - operand not in scope
                            Nothing

                        Just operandType ->
                            if not (isEcoValueType operandType) then
                                Just
                                    { opId = op.id
                                    , opName = op.name
                                    , message =
                                        "eco.unbox operand '"
                                            ++ operandName
                                            ++ "' is not eco.value, got "
                                            ++ typeToString operandType
                                    }

                            else if not (isPrimitiveType resultType) then
                                Just
                                    { opId = op.id
                                    , opName = op.name
                                    , message =
                                        "eco.unbox result is not primitive, got "
                                            ++ typeToString resultType
                                    }

                            else
                                Nothing

                _ ->
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            "eco.unbox should have exactly 1 result, has "
                                ++ String.fromInt (List.length op.results)
                        }

        _ ->
            Just
                { opId = op.id
                , opName = op.name
                , message =
                    "eco.unbox should have exactly 1 operand, has "
                        ++ String.fromInt (List.length op.operands)
                }



-- TYPE ENV BUILDING (per-function)


{-| Build a TypeEnv from a single function op.
-}
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



-- OP WALKING (within function)


walkOpsInOp : MlirOp -> List MlirOp
walkOpsInOp op =
    List.concatMap walkOpsInRegion op.regions


walkOp : MlirOp -> List MlirOp
walkOp op =
    op :: List.concatMap walkOpsInRegion op.regions



-- HELPERS


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



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkEcoUnboxSanity mlirModule)



-- TEST CASES


intUnboxTest : () -> Expectation
intUnboxTest _ =
    -- Integer arithmetic: x + 1 where x is Int
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "x" ]
                    (binopsExpr [ ( varExpr "x", "+" ) ] (intExpr 1))
                )
    in
    runInvariantTest modul


floatUnboxTest : () -> Expectation
floatUnboxTest _ =
    -- Float arithmetic: x * 2.0 where x is Float
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "x" ]
                    (binopsExpr [ ( varExpr "x", "*" ) ] (floatExpr 2.0))
                )
    in
    runInvariantTest modul


boolUnboxTest : () -> Expectation
boolUnboxTest _ =
    -- Boolean condition: if b then 1 else 0
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "b" ]
                    (ifExpr (varExpr "b") (intExpr 1) (intExpr 0))
                )
    in
    runInvariantTest modul


charUnboxTest : () -> Expectation
charUnboxTest _ =
    -- Character case expression: pattern matching on Char triggers unboxing
    let
        modul =
            makeModuleWithTypedDefsUnionsAliases "Test"
                [ { name = "testValue"
                  , args = [ pVar "c" ]
                  , tipe = tLambda (tType "Char" []) (tType "Int" [])
                  , body =
                        caseExpr (varExpr "c")
                            [ ( pChr "a", intExpr 1 )
                            , ( pChr "b", intExpr 2 )
                            , ( pVar "_", intExpr 0 )
                            ]
                  }
                ]
                []
                []
    in
    runInvariantTest modul


arithmeticUnboxTest : () -> Expectation
arithmeticUnboxTest _ =
    -- Multiple arithmetic operations: a * 2 + b - 1
    let
        modul =
            makeModule "testValue"
                (lambdaExpr [ pVar "a", pVar "b" ]
                    (binopsExpr
                        [ ( binopsExpr [ ( varExpr "a", "*" ) ] (intExpr 2), "+" )
                        , ( varExpr "b", "-" )
                        ]
                        (intExpr 1)
                    )
                )
    in
    runInvariantTest modul
