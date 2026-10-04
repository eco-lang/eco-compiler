module TestLogic.Generate.CodeGen.SsaUniquenessTest exposing (suite)

{-| Generated MLIR must not define an SSA name that is already visible where the
definition is made. These tests look for such a redefinition in the MLIR
compiled from the standard catalogue of test programs, so that a
code-generation change that breaks the rule on one of those programs is
reported.

An _SSA name_ is the name of a value that is defined once, as a block argument
or as the result of an operation, and then read by name. The regions of a
`func.func` start with no names visible. The regions of other operations, such
as the alternatives of an `eco.case`, also see the names defined before the
operation that holds them, and that operation's own results, so reusing one of
those names inside such a region is a redefinition.

The programs are those of `SourceIR.Suite.StandardTestSuites`, each given in
turn to `TestLogic.Generate.CodeGen.SsaUniqueness.expectSsaUniqueness`, whose
module docstring states the rule as checked.

  - `suite` compiles each program to MLIR and walks the first region of each
    top-level `func.func`. An operation result whose name is already visible
    fails the test. A program that does not compile to MLIR also fails.

Among what is not tested:

  - A block argument that repeats a visible name.
  - A name defined in two blocks of the same region, or in two sibling
    regions.
  - The regions of a `func.func` nested inside another operation, and any
    region of a `func.func` after the first.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.SsaUniqueness exposing (expectSsaUniqueness)


{-| The group of tests that checks SSA name uniqueness in the MLIR compiled from
each program of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "SSA Uniqueness"
        [ StandardTestSuites.expectSuite expectSsaUniqueness "passes SSA uniqueness invariant"
        ]
