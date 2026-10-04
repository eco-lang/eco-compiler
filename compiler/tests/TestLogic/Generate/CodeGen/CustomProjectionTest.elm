module TestLogic.Generate.CodeGen.CustomProjectionTest exposing (suite)

{-| These tests look for a malformed `eco.project.custom` op in the MLIR the
compiler generates for a wide range of programs. An `eco.project.custom` op
reads one field of a custom type value.

The fixture is the standard catalogue of `SourceIR` test programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers. This module adds no
programs of its own.

What the tests establish:

  - `suite` gives each catalogue program to
    `TestLogic.Generate.CodeGen.CustomProjection.expectCustomProjection`, which
    passes when the program compiles to MLIR and no `eco.project.custom` op in
    it lacks an integer `field_index`, has a negative one, or has other than
    one operand or one result.

Among what is not tested: whether `field_index` is less than the number of
fields the constructor has, and whether every field read of a custom type value
uses `eco.project.custom` at all.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CustomProjection exposing (expectCustomProjection)


{-| The group of tests that checks every program in the standard catalogue with
`expectCustomProjection`.
-}
suite : Test
suite =
    Test.describe "CGEN_024: Custom ADT Projection"
        [ StandardTestSuites.expectSuite expectCustomProjection "passes custom projection invariant"
        ]
