module TestLogic.Generate.CodeGen.ConstructResultTypeTest exposing (suite)

{-| Runs the check that every construct op in the generated MLIR has a single
result of type `!eco.value`, the type of a boxed value, over every program in
the standard `SourceIR` catalogue. Without it, a construct op emitted with
another result type, or with no result or several, would go unnoticed in those
programs.

A _construct op_ is any op whose name starts with `eco.construct.`.

The fixture is the catalogue that `SourceIR.Suite.StandardTestSuites` assembles.
Each program in it is compiled to MLIR by
`TestLogic.TestPipeline.runToMlir`.

What `suite` establishes, for each program, through
`TestLogic.Generate.CodeGen.ConstructResultType.expectConstructResultType`:

  - the program compiles to MLIR;
  - every construct op, at any depth, has exactly one result, and its type is
    `!eco.value`.

Among what is not tested: a construct op's operands and attributes, and a value
built by an op not named `eco.construct.`, such as `eco.make.custom` or
`eco.to_heap`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.ConstructResultType exposing (expectConstructResultType)


{-| The standard catalogue of programs, each checked with
`expectConstructResultType`, gathered under one `describe`.
-}
suite : Test
suite =
    Test.describe "CGEN_025: Construct Result Types"
        [ StandardTestSuites.expectSuite expectConstructResultType "passes construct result type invariant"
        ]
