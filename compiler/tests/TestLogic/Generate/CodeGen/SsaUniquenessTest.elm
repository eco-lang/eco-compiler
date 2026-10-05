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

  - `suite` compiles each program to MLIR and walks every region of each
    `func.func`, top-level or nested. A block argument or operation result
    whose name is already visible, including one defined in an earlier block
    of the same region, fails the test. A program that does not compile to
    MLIR also fails.

Among what is not tested: a name defined in two sibling regions, which MLIR
allows.

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
