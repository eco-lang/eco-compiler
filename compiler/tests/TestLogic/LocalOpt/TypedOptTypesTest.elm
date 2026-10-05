module TestLogic.LocalOpt.TypedOptTypesTest exposing (suite)

{-| These tests catch an expression produced by typed optimization whose type
is malformed, in any of the standard test programs: a named type that does not
exist, or a type or alias applied to the wrong number of arguments.

The fixture is the standard catalogue of `SourceIR` test programs, as
`SourceIR.Suite.StandardTestSuites` assembles it. Most of its programs are
fixed; those of its fuzz modules can vary from run to run.

What the tests establish:

  - `suite` hands `TestLogic.LocalOpt.TypedOptTypes.expectAllExprsHaveTypes` to
    `StandardTestSuites.expectSuite`, which applies it to the catalogue's
    programs. For a program, that expectation fails when
    `TestLogic.TestPipeline.runToTypedOpt` returns an error, or when a type
    stored on any expression of the program's typed local graph (or on a
    function parameter, `let` definition or destructured name) names an
    unknown type, or applies a type or alias to the wrong number of
    arguments.

Among what is not tested: whether those types are the right types for their
expressions, and whether their type variables are bound.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.LocalOpt.TypedOptTypes exposing (expectAllExprsHaveTypes)


{-| The test group that applies `expectAllExprsHaveTypes` to the programs of
the standard catalogue.
-}
suite : Test
suite =
    Test.describe "TypedOptimized expressions carry well-formed types (TOPT_001)"
        [ StandardTestSuites.expectSuite expectAllExprsHaveTypes "has well-formed types on all expressions"
        ]
