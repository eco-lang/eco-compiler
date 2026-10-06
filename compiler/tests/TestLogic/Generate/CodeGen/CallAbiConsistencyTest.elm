module TestLogic.Generate.CodeGen.CallAbiConsistencyTest exposing (suite)

{-| A call that passes an operand of a type its callee does not declare hands
the callee a value in a representation it does not expect, such as a Bool as
`i1` where the parameter is `!eco.value`. `Mlir.Mlir` does not tie a call's
operand types to its callee's signature, so such a call is built without
complaint. These tests look for one in the MLIR generated for each program of
the standard catalogue.

The fixture is that catalogue: the programs built by the case modules that
`SourceIR.Suite.StandardTestSuites` lists, each compiled with
`TestLogic.TestPipeline.runToMlir`.

What the tests establish, for each program, through
`TestLogic.Generate.CodeGen.CallAbiConsistency.expectCallAbiConsistency`:

  - the program compiles to MLIR; if it does not, the test that runs it fails
    with the test pipeline's error message;
  - each `eco.call` whose callee is a top-level `func.func` with a
    `function_type` has, once its trailing GC-root hint operands (operands
    appended after the arguments for the garbage collector, as many as its
    `eco.gc_roots_count` attribute says) are dropped, one operand for each of
    the callee's parameters, and each operand type equals the parameter type at
    the same position.

Among what is not tested:

  - an `eco.call` whose callee has no top-level `func.func` with a
    `function_type`, that has no `callee`, or that has operands but no
    `_operand_types` attribute;
  - the result types of a call;
  - any program outside the catalogue, except `wideCtorCallTest`, which calls
    the constructor function of a constructor whose field 24 is stored boxed.

-}

import Compiler.AST.SourceBuilder
    exposing
        ( TypedDef
        , UnionDef
        , callExpr
        , caseExpr
        , ctorExpr
        , intExpr
        , makeModuleWithTypedDefsUnionsAliases
        , pCtor
        , pVar
        , tLambda
        , tType
        , varExpr
        )
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CallAbiConsistency exposing (expectCallAbiConsistency)


{-| The tests that run the call operand type check on every program of the
standard catalogue, grouped under one `describe`.
-}
suite : Test
suite =
    Test.describe "REP_ABI_001: Call ABI Consistency"
        [ StandardTestSuites.expectSuite expectCallAbiConsistency "passes call ABI consistency invariant"
        , wideCtorCallTest
        ]


{-| A call to the constructor function of a constructor with 25 `Int` fields.
`computeCtorLayout` stores field 24 unboxed as `i64`; the constructor
function's parameter and slot are both `i64`, and the call's operand must
agree with the parameter. The test still pins REP\_ABI\_001 for constructors
wider than the header bitmap. The program declares
`type Wide = Wide Int ... Int` (25 fields), a `lastField : Wide -> Int` that
matches it, and `testValue = lastField (Wide 0 1 ... 24)`.
-}
wideCtorCallTest : Test
wideCtorCallTest =
    Test.test "constructor with 25 Int fields is called with matching operand types" <|
        \_ ->
            let
                fieldNames =
                    List.map (\i -> "f" ++ String.fromInt i) (List.range 0 24)

                wideUnion : UnionDef
                wideUnion =
                    { name = "Wide"
                    , args = []
                    , ctors = [ { name = "Wide", args = List.map (\_ -> tType "Int" []) fieldNames } ]
                    }

                lastFieldDef : TypedDef
                lastFieldDef =
                    { name = "lastField"
                    , args = [ pVar "w" ]
                    , tipe = tLambda (tType "Wide" []) (tType "Int" [])
                    , body = caseExpr (varExpr "w") [ ( pCtor "Wide" (List.map pVar fieldNames), varExpr "f24" ) ]
                    }

                testValueDef : TypedDef
                testValueDef =
                    { name = "testValue"
                    , args = []
                    , tipe = tType "Int" []
                    , body = callExpr (varExpr "lastField") [ callExpr (ctorExpr "Wide") (List.map intExpr (List.range 0 24)) ]
                    }
            in
            makeModuleWithTypedDefsUnionsAliases "Test" [ lastFieldDef, testValueDef ] [ wideUnion ] []
                |> expectCallAbiConsistency
