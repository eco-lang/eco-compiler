module TestLogic.Generate.CodeGen.DbgTypeIdsTest exposing (suite)

{-| These tests look for an `eco.dbg` op in the generated MLIR that cites a
type ID pointing outside the module's type table, across a wide range of
programs.

The type table is the `eco.type_table` op in the module's top-level body, and a
type ID is a position in its `types` array, as
`TestLogic.Generate.CodeGen.DbgTypeIds` describes.

The fixture is the standard catalogue of `SourceIR` test programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` gathers. This module adds no
programs of its own.

What the tests establish:

  - `suite` gives each catalogue program to
    `TestLogic.Generate.CodeGen.DbgTypeIds.expectDbgTypeIds`, which passes when
    the program compiles to MLIR and every entry of each `eco.dbg` op's array
    `arg_type_ids` is an integer from 0 to one less than the length of the
    first top-level type table's `types` array. An `eco.dbg` op carrying a
    non-empty `arg_type_ids` in a module with no type table fails.

A program whose MLIR has no `eco.dbg` op carrying a non-empty `arg_type_ids`
passes.

Among what is not tested: whether a type ID names the type of the value being
logged, and anything about the type table beyond the length of its `types`
array.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.DbgTypeIds exposing (expectDbgTypeIds)


{-| The group of tests that checks every program in the standard catalogue with
`expectDbgTypeIds`.
-}
suite : Test
suite =
    Test.describe "CGEN_036: Dbg Type IDs Valid"
        [ StandardTestSuites.expectSuite expectDbgTypeIds "passes dbg type IDs invariant"
        ]
