module TestLogic.Generate.CodeGen.PapCreateArityTest exposing (suite)

{-| Test suite for CGEN_033: PapCreate Arity Constraints invariant.

`eco.papCreate` requires:

  - `arity > 0`
  - `num_captured == operand count`
  - `num_captured < arity`

-}

import TestLogic.Generate.CodeGen.PapCreateArity exposing (expectPapCreateArity)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_033: PapCreate Arity Constraints"
        [ StandardTestSuites.expectSuite expectPapCreateArity "passes papCreate arity invariant"
        ]
