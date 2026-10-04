module TestLogic.Generate.CodeGen.SymbolUniquenessTest exposing (suite)

{-| An MLIR op can define a name, its `sym_name` attribute, by which other ops
refer to it. When two top-level ops of one module define the same name, a
reference to it could mean either op. These tests look for such a name in the
MLIR the code generator produces for the standard test programs.

The programs are those built by the case modules that
`SourceIR.Suite.StandardTestSuites` gathers. Each is compiled to MLIR by
`TestLogic.TestPipeline.runToMlir` and handed to
`TestLogic.Generate.CodeGen.SymbolUniqueness.expectSymbolUniqueness`.

What the tests establish:

  - The check on a program fails if it does not compile to MLIR, or if two or
    more of the module's top-level ops carry the same `sym_name`, whatever kind
    of op they are.

Among what is not tested: ops nested in another op's regions, whether every
name that is referred to is defined, programs outside the standard catalogue,
and MLIR produced by a real build rather than the test pipeline.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.SymbolUniqueness exposing (expectSymbolUniqueness)


{-| The symbol uniqueness check applied to the standard test programs, as one
group of tests.
-}
suite : Test
suite =
    Test.describe "CGEN_041: Symbol Uniqueness"
        [ StandardTestSuites.expectSuite expectSymbolUniqueness "passes symbol uniqueness invariant"
        ]
