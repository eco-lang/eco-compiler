module Compiler.Generate.CodeGen.CharTypeMappingTest exposing (suite)

{-| Test suite for CGEN_015: Char Type Mapping invariant.

`monoTypeToMlir` must map `MChar` to `i16` (not `i32`),
and all char constants/ops must use `i16`.

-}

import Compiler.Generate.CodeGen.CharTypeMapping exposing (expectCharTypeMapping)
import Compiler.StandardTestSuites as StandardTestSuites
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CGEN_015: Char Type Mapping"
        [ StandardTestSuites.expectSuite expectCharTypeMapping "passes char type mapping invariant"
        ]
