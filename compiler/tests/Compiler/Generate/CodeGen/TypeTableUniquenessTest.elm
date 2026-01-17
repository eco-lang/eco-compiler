module Compiler.Generate.CodeGen.TypeTableUniquenessTest exposing (suite)

{-| Tests for CGEN_035: Type Table Uniqueness invariant.

Each module must have at most one `eco.type_table` op at module scope.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder
    exposing
        ( intExpr
        , makeModule
        , strExpr
        , tuple3Expr
        )
import Compiler.Generate.CodeGen.GenerateMLIR exposing (compileToMlirModule)
import Compiler.Generate.CodeGen.Invariants
    exposing
        ( Violation
        , violationsToExpectation
        )
import Expect exposing (Expectation)
import Mlir.Mlir exposing (MlirModule)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_035: Type Table Uniqueness"
        [ Test.test "Module has at most one type table" singleTypeTableTest
        , Test.test "Simple module type table" simpleModuleTypeTableTest
        , Test.test "Complex module type table" complexModuleTypeTableTest
        ]



-- INVARIANT CHECKER


{-| Check type table uniqueness invariants.
-}
checkTypeTableUniqueness : MlirModule -> List Violation
checkTypeTableUniqueness mlirModule =
    let
        -- Only check top-level ops (module.body), not nested
        typeTableOps =
            List.filter (\op -> op.name == "eco.type_table") mlirModule.body

        typeTableCount =
            List.length typeTableOps
    in
    if typeTableCount > 1 then
        [ { opId = "module"
          , opName = "module"
          , message =
                "Module has "
                    ++ String.fromInt typeTableCount
                    ++ " eco.type_table ops, expected at most 1"
          }
        ]

    else
        []



-- TEST HELPER


runInvariantTest : Src.Module -> Expectation
runInvariantTest srcModule =
    case compileToMlirModule srcModule of
        Err err ->
            Expect.fail ("Compilation failed: " ++ err)

        Ok { mlirModule } ->
            violationsToExpectation (checkTypeTableUniqueness mlirModule)



-- TEST CASES


singleTypeTableTest : () -> Expectation
singleTypeTableTest _ =
    runInvariantTest (makeModule "testValue" (intExpr 42))


simpleModuleTypeTableTest : () -> Expectation
simpleModuleTypeTableTest _ =
    runInvariantTest (makeModule "testValue" (strExpr "hello"))


complexModuleTypeTableTest : () -> Expectation
complexModuleTypeTableTest _ =
    runInvariantTest
        (makeModule "testValue"
            (tuple3Expr (intExpr 1) (strExpr "world") (intExpr 3))
        )
