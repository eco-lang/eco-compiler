module TestLogic.LocalOpt.FunctionTypeEncodeTest exposing (suite)

{-| These tests exist so that a function expression whose own type has fewer
arrows than it has parameters cannot leave typed optimization unnoticed in any
of the standard test programs.

A _function expression_ is a `Function` or `TrackedFunction` in the
typed-optimized IR (`Compiler.AST.TypedOptimized`), and it carries the type of
the function as a whole. An _arrow_ is one `Can.TLambda` layer of that type.

The fixture is the standard catalogue of `SourceIR` test programs, as
`SourceIR.Suite.StandardTestSuites` assembles it. Most of its programs are
fixed; those of its fuzz modules can vary from run to run.

What the tests establish:

  - `suite` hands `TestLogic.LocalOpt.FunctionTypeEncode.expectFunctionTypesEncoded`
    to `StandardTestSuites.expectSuite`, which applies it to the catalogue's
    programs. For a program, that expectation fails when
    `TestLogic.TestPipeline.runToTypedOpt` returns an error, or when a function
    expression its walk reaches has fewer `Can.TLambda` layers in its type than
    it has parameters.

Among what is not tested:

  - Whether the arrows' argument types equal the parameter types, or whether
    the type after the last parameter is the body's type. Arrows are counted,
    not compared.
  - Function expressions in a `Cycle` node's values, or in branches a `Case`
    inlines into its decision tree, which the walk does not visit.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.FunctionTypeEncode exposing (expectFunctionTypesEncoded)


{-| The test group that applies `expectFunctionTypesEncoded` to the programs of
the standard catalogue.
-}
suite : Test
suite =
    Test.describe "Function expressions encode full function type (TOPT_005)"
        [ StandardTestSuites.expectSuite expectFunctionTypesEncoded "has correctly encoded function types"
        ]
