module TestLogic.Generate.CodeGen.CharTypeMappingTest exposing (suite)

{-| Test suite for CGEN_015: Char Type Mapping invariant.

`monoTypeToMlir` must map `MChar` to `i16` (not `i32`),
and all char constants/ops must use `i16`.

-}

import TestLogic.Generate.CodeGen.CharTypeMapping exposing (expectCharTypeMapping)
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_015: Char Type Mapping"
        [ StandardTestSuites.expectSuite expectCharTypeMapping "passes char type mapping invariant"
        ]
