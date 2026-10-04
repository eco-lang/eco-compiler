module TestLogic.LocalOpt.TypedOptTypesTest exposing (suite)

{-| These tests are meant to catch an expression produced by typed optimization
that does not carry a usable type, in any of the standard test programs. As the
checker stands, they catch only a program that fails to get through typed
optimization.

The fixture is the standard catalogue of `SourceIR` test programs, as
`SourceIR.Suite.StandardTestSuites` assembles it. Most of its programs are
fixed; those of its fuzz modules can vary from run to run.

What the tests establish:

  - `suite` hands `TestLogic.LocalOpt.TypedOptTypes.expectAllExprsHaveTypes` to
    `StandardTestSuites.expectSuite`, which applies it to the catalogue's
    programs. For a program, that expectation fails when
    `TestLogic.TestPipeline.runToTypedOpt` returns an error. It also walks the
    program's typed local graph and tests the type of each expression it
    reaches, but that test reports nothing for any type, so it cannot make the
    expectation fail.

Among what is not tested:

  - The shape of any expression's type. Every typed-optimized expression holds
    a `Can.Type`, so a type cannot be absent, and nothing here looks at what
    the type contains.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.TypedOptTypes exposing (expectAllExprsHaveTypes)


{-| The test group that applies `expectAllExprsHaveTypes` to the programs of
the standard catalogue.
-}
suite : Test
suite =
    Test.describe "TypedOptimized expressions always carry types (TOPT_001)"
        [ StandardTestSuites.expectSuite expectAllExprsHaveTypes "has types on all expressions"
        ]
