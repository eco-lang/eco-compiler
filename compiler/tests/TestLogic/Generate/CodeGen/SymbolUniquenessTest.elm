module TestLogic.Generate.CodeGen.SymbolUniquenessTest exposing (suite)

{-| Test suite for CGEN\_041: Symbol Uniqueness invariant.

Within a module, all symbol definitions must be unique: no two `func.func`
operations may have the same `sym_name`.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.CodeGen.SymbolUniqueness exposing (expectSymbolUniqueness)


suite : Test
suite =
    Test.describe "CGEN_041: Symbol Uniqueness"
        [ StandardTestSuites.expectSuite expectSymbolUniqueness "passes symbol uniqueness invariant"
        ]
