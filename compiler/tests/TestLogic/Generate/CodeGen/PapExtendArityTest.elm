module TestLogic.Generate.CodeGen.PapExtendArityTest exposing (suite)

{-| Test suite for CGEN\_052: PapExtend remaining\_arity calculation invariant.

`eco.papExtend` requires:

  - `remaining_arity = source_pap_arity - num_new_args`
  - `remaining_arity >= 0`

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.PapExtendArity exposing (expectPapExtendArity)


suite : Test
suite =
    Test.describe "CGEN_052: PapExtend remaining_arity calculation"
        [ StandardTestSuites.expectSuite expectPapExtendArity "passes papExtend remaining_arity invariant"
        ]
