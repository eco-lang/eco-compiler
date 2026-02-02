module TestLogic.Generate.CodeGen.DbgTypeIdsTest exposing (suite)

{-| Test suite for CGEN\_036: Dbg Type IDs Valid invariant.

When `eco.dbg` has `arg_type_ids`, each ID must reference a valid type table entry.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.DbgTypeIds exposing (expectDbgTypeIds)


suite : Test
suite =
    Test.describe "CGEN_036: Dbg Type IDs Valid"
        [ StandardTestSuites.expectSuite expectDbgTypeIds "passes dbg type IDs invariant"
        ]
