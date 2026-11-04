module TestLogic.LocalOpt.FunctionTypeEncodeTest exposing (suite)

{-| These tests exist so that a function expression whose own type disagrees
with its parameters or its body, such as one with fewer arrows than it has
parameters, cannot leave typed optimization unnoticed in any of the standard
test programs.

A _function expression_ is a `Function` or `TrackedFunction` in the
typed-optimized IR (`Compiler.IR.Typed.Optimized`), and it carries the type of
the function as a whole.

The fixture is the standard catalogue of `SourceIR` test programs, as
`SourceIR.Suite.StandardTestSuites` assembles it. Most of its programs are
fixed; those of its fuzz modules can vary from run to run.

What the tests establish:

  - `suite` hands `TestLogic.LocalOpt.FunctionTypeEncode.expectFunctionTypesEncoded`
    to `StandardTestSuites.expectSuite`, which applies it to the catalogue's
    programs. For a program, that expectation fails when
    `TestLogic.TestPipeline.runToTypedOpt` returns an error, or when a function
    expression anywhere in it has a type that does not match
    `p1 -> ... -> pn -> r`, built from its parameter types and its body's
    type, under `TestLogic.LocalOpt.Typed.TypeEq.alphaEqStrict`.

Among what is not tested: the parameters of a tail-recursive `let` definition
against that definition's type.

It also runs over the programs of `SourceIR.MonoFailsCases`
(`expectBeforeMonoSuite`), which monomorphization rejects: every stage this
check looks at accepts them, and they hold what the standard catalogue cannot,
such as polymorphic recursion over a non-regular type.

-}

import SourceIR.MonoFailsCases as MonoFailsCases
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
        , MonoFailsCases.expectBeforeMonoSuite expectFunctionTypesEncoded "has correctly encoded function types"
        ]
