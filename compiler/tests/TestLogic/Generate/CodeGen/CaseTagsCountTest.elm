module TestLogic.Generate.CodeGen.CaseTagsCountTest exposing (suite)

{-| These tests run the check of `TestLogic.Generate.CodeGen.CaseTagsCount`
over the standard catalogue of test programs, so that an `eco.case` with no
`tags` array, or with one whose length differs from its number of alternatives,
in the MLIR generated for any of those programs, fails a test.

An `eco.case` chooses one of its regions, the _alternatives_, by the value it
branches on. Its `tags` attribute is an array holding the tag for each
alternative, and nothing in `Mlir.Mlir` ties the length of that array to the
number of regions.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gathers from the `SourceIR` case modules; that module says which are included.

Each program is compiled to MLIR with `TestLogic.TestPipeline.runToMlir`. The
expectation applied to it establishes:

  - The program compiles through `runToMlir` without an error.
  - Every op named `eco.case` in the generated module, at any depth, has a
    `tags` attribute that is an array, and the array is as long as the op's
    list of regions.

When several `eco.case` ops fail, only the first is reported.

Among what is not tested: the values of the tags, the kind of their elements,
and the `string_patterns` attribute of a string case.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.CaseTagsCount exposing (expectCaseTagsCount)


{-| The tests of this module: every program of the standard catalogue, each
checked with `expectCaseTagsCount`.
-}
suite : Test
suite =
    Test.describe "CGEN_029: Case Tags Count"
        [ StandardTestSuites.expectSuite expectCaseTagsCount "passes case tags count invariant"
        ]
