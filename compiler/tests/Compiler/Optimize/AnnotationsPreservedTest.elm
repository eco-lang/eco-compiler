module Compiler.Optimize.AnnotationsPreservedTest exposing (suite)

{-| Test suite for invariant TOPT_003: Top-level annotations preserved in local graph.

-}

import Compiler.AST.Source as Src
import Compiler.AnnotatedTests as AnnotatedTests
import Compiler.FunctionTests as FunctionTests
import Compiler.LetTests as LetTests
import Compiler.MultiDefTests as MultiDefTests
import Compiler.Optimize.AnnotationsPreserved exposing (expectAnnotationsPreserved)
import Compiler.RecordTests as RecordTests
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Top-level annotations preserved in local graph (TOPT_003)"
        [ expectSuite expectAnnotationsPreserved "has preserved annotations"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ AnnotatedTests.expectSuite expectFn condStr
        , FunctionTests.expectSuite expectFn condStr
        , LetTests.expectSuite expectFn condStr
        , MultiDefTests.expectSuite expectFn condStr
        , RecordTests.expectSuite expectFn condStr
        ]
