module Compiler.Generate.CodeGen.ConstructResultTypeTest exposing (suite)

{-| Tests for CGEN_025: Construct Result Types invariant.

All `eco.construct.*` ops must produce `!eco.value` result type.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( UnionDef
        , callExpr
        , ctorExpr
        , intExpr
        , listExpr
        , makeModule
        , makeModuleWithTypedDefsUnionsAliases
        , recordExpr
        , strExpr
        , tType
        , tVar
        , tuple3Expr
        , tupleExpr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , ecoValueType
        , findOpsWithPrefix
        , isEcoValueType
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule, MlirOp, MlirType(..))
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_025: Construct Result Types"
        [ Test.test "eco.construct.list produces !eco.value" listConstructResultTest
        , Test.test "eco.construct.tuple2 produces !eco.value" tuple2ConstructResultTest
        , Test.test "eco.construct.tuple3 produces !eco.value" tuple3ConstructResultTest
        , Test.test "eco.construct.record produces !eco.value" recordConstructResultTest
        , Test.test "eco.construct.custom produces !eco.value" customConstructResultTest
        , Test.test "All construct ops produce exactly 1 result" singleResultTest
        ]



-- INVARIANT CHECKER


{-| Check that all construct ops produce !eco.value result.
-}
checkConstructResultTypes : MlirModule -> List Violation
checkConstructResultTypes mlirModule =
    let
        constructOps =
            findOpsWithPrefix "eco.construct." mlirModule

        violations =
            List.filterMap checkConstructResultType constructOps
    in
    violations


checkConstructResultType : MlirOp -> Maybe Violation
checkConstructResultType op =
    let
        resultCount =
            List.length op.results
    in
    if resultCount /= 1 then
        Just
            { opId = op.id
            , opName = op.name
            , message =
                op.name
                    ++ " should have exactly 1 result, has "
                    ++ String.fromInt resultCount
            }

    else
        case List.head op.results of
            Just ( _, resultType ) ->
                if not (isEcoValueType resultType) then
                    Just
                        { opId = op.id
                        , opName = op.name
                        , message =
                            op.name
                                ++ " result type should be !eco.value, got "
                                ++ typeToString resultType
                        }

                else
                    Nothing

            Nothing ->
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
            violationsToExpectation (checkConstructResultTypes mlirModule)



-- TEST CASES


listConstructResultTest : () -> Expectation
listConstructResultTest _ =
    runInvariantTest (makeModule "testValue" (listExpr [ intExpr 1, intExpr 2 ]))


tuple2ConstructResultTest : () -> Expectation
tuple2ConstructResultTest _ =
    runInvariantTest (makeModule "testValue" (tupleExpr (intExpr 1) (intExpr 2)))


tuple3ConstructResultTest : () -> Expectation
tuple3ConstructResultTest _ =
    runInvariantTest (makeModule "testValue" (tuple3Expr (intExpr 1) (intExpr 2) (intExpr 3)))


recordConstructResultTest : () -> Expectation
recordConstructResultTest _ =
    runInvariantTest
        (makeModule "testValue"
            (recordExpr
                [ ( "x", intExpr 1 )
                , ( "y", strExpr "hello" )
                ]
            )
        )


customConstructResultTest : () -> Expectation
customConstructResultTest _ =
    runInvariantTest (makeModuleWithMaybe "testValue" (callExpr (ctorExpr "Just") [ intExpr 5 ]))


singleResultTest : () -> Expectation
singleResultTest _ =
    -- Test multiple construct types to ensure they all have single results
    let
        list =
            listExpr [ intExpr 1 ]

        record =
            recordExpr [ ( "a", intExpr 2 ) ]

        custom =
            callExpr (ctorExpr "Just") [ intExpr 3 ]
    in
    runInvariantTest
        (makeModuleWithMaybe "testValue"
            (tuple3Expr list record custom)
        )
