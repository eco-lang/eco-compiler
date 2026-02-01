module TestLogic.Generate.CodeGen.PapArityConsistencyTest exposing (suite)

{-| Test suite for CGEN_051: papCreate arity matches function parameter count.

`eco.papCreate` arity must equal the number of arguments its referenced
function symbol accepts.

-}

import TestLogic.Generate.CodeGen.PapArityConsistency exposing (expectPapArityConsistency)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_051: PapCreate arity matches function parameters"
        [ StandardTestSuites.expectSuite expectPapArityConsistency "passes papCreate arity consistency invariant"
        ]
