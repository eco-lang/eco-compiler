module Compiler.Generate.MonoNumericResolutionTest exposing (suite)

{-| Test suite for invariants:

  - MONO_002: No CNumber MVar at MLIR codegen entry
  - MONO_008: Primitive numeric types are fixed in calls

-}

import Compiler.AST.Source as Src
import Compiler.FunctionTests as FunctionTests
import Compiler.Generate.MonoNumericResolution exposing
    ( expectNoNumericPolymorphism
    , expectNumericTypesResolved
    )
import Compiler.LetTests as LetTests
import Compiler.MultiDefTests as MultiDefTests
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Numeric type resolution in monomorphization"
        [ noNumericPolymorphismSuite
        , numericTypesResolvedSuite
        ]


noNumericPolymorphismSuite : Test
noNumericPolymorphismSuite =
    Test.describe "No CNumber MVar at MLIR entry (MONO_002)"
        [ expectSuite expectNoNumericPolymorphism "has no CNumber MVars"
        ]


numericTypesResolvedSuite : Test
numericTypesResolvedSuite =
    Test.describe "Numeric types fixed at call sites (MONO_008)"
        [ expectSuite expectNumericTypesResolved "has resolved numeric types"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ FunctionTests.expectSuite expectFn condStr
        , LetTests.expectSuite expectFn condStr
        , MultiDefTests.expectSuite expectFn condStr
        ]
