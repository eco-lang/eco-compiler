module Compiler.Generate.TypedOptimizedMonomorphizeTest exposing (suite)

{-| Test suite for verifying that TypedOptimized code can be monomorphized.

This runs all the standard test cases (excluding TypeCheckFails) through
the typed optimization pipeline and then monomorphization.

-}

import Compiler.AnnotatedTests as AnnotatedTests
import Compiler.AsPatternTests as AsPatternTests
import Compiler.BinopTests as BinopTests
import Compiler.CaseTests as CaseTests
import Compiler.DeepFuzzTests as DeepFuzzTests
import Compiler.EdgeCaseTests as EdgeCaseTests
import Compiler.FunctionTests as FunctionTests
import Compiler.Generate.TypedOptimizedMonomorphize exposing (expectMonomorphization)
import Compiler.HigherOrderTests as HigherOrderTests
import Compiler.LetDestructTests as LetDestructTests
import Compiler.LetRecTests as LetRecTests
import Compiler.LetTests as LetTests
import Compiler.ListTests as ListTests
import Compiler.LiteralTests as LiteralTests
import Compiler.MultiDefTests as MultiDefTests
import Compiler.OperatorTests as OperatorTests
import Compiler.PatternArgTests as PatternArgTests
import Compiler.RecordTests as RecordTests
import Compiler.TupleTests as TupleTests
import Test exposing (Test)


suite : Test
suite =
    Test.describe "TypedOptimized code monomorphizes successfully"
        [ AnnotatedTests.expectSuite expectMonomorphization "monomorphizes"
        , AsPatternTests.expectSuite expectMonomorphization "monomorphizes"
        , BinopTests.expectSuite expectMonomorphization "monomorphizes"
        , CaseTests.expectSuite expectMonomorphization "monomorphizes"
        , EdgeCaseTests.expectSuite expectMonomorphization "monomorphizes"
        , FunctionTests.expectSuite expectMonomorphization "monomorphizes"
        , HigherOrderTests.expectSuite expectMonomorphization "monomorphizes"
        , LetDestructTests.expectSuite expectMonomorphization "monomorphizes"
        , LetRecTests.expectSuite expectMonomorphization "monomorphizes"
        , LetTests.expectSuite expectMonomorphization "monomorphizes"
        , ListTests.expectSuite expectMonomorphization "monomorphizes"
        , LiteralTests.expectSuite expectMonomorphization "monomorphizes"
        , MultiDefTests.expectSuite expectMonomorphization "monomorphizes"
        , OperatorTests.expectSuite expectMonomorphization "monomorphizes"
        , PatternArgTests.expectSuite expectMonomorphization "monomorphizes"
        , RecordTests.expectSuite expectMonomorphization "monomorphizes"
        , TupleTests.expectSuite expectMonomorphization "monomorphizes"

        -- Deep structural fuzz tests
        , DeepFuzzTests.expectSuite expectMonomorphization "monomorphizes"
        ]
