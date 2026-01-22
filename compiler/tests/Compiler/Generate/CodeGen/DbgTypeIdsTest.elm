module Compiler.Generate.CodeGen.DbgTypeIdsTest exposing (suite)

{-| Test suite for CGEN_036: Dbg Type IDs Valid invariant.

When `eco.dbg` has `arg_type_ids`, each ID must reference a valid type table entry.

-}

import Compiler.Generate.CodeGen.DbgTypeIds exposing (expectDbgTypeIds)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_036: Dbg Type IDs Valid"
        [ StandardTestSuites.expectSuite expectDbgTypeIds "passes dbg type IDs invariant"
        ]
