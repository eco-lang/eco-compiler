module Compiler.Type.Constrain.TypedErasedCheckingParityTest exposing (suite)

{-| Consolidated test suite for ID assignment verification.

This module gathers all individual test suites and runs them with the
appropriate expectation functions.

-}

import Compiler.AST.Source as Src
import Compiler.AnnotatedTests as AnnotatedTests
import Compiler.AsPatternTests as AsPatternTests
import Compiler.BinopTests as BinopTests
import Compiler.CaseTests as CaseTests
import Compiler.DeepFuzzTests as DeepFuzzTests
import Compiler.EdgeCaseTests as EdgeCaseTests
import Compiler.FunctionTests as FunctionTests
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
import Compiler.Type.Constrain.TypedErasedCheckingParity
    exposing
        ( expectEquivalentTypeChecking
        , expectEquivalentTypeCheckingFails
        )
import Compiler.TypeCheckFails as TypeCheckFails
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Equivalenve of type checking with and without ids"
        [ expectSuite expectEquivalentTypeChecking "check equivalently"
        , typeCheckFailsSuite
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe "Type solver constrain and constrinWithIds type check equivalently"
        [ AnnotatedTests.expectSuite expectFn condStr
        , AsPatternTests.expectSuite expectFn condStr
        , BinopTests.expectSuite expectFn condStr
        , CaseTests.expectSuite expectFn condStr
        , EdgeCaseTests.expectSuite expectFn condStr
        , FunctionTests.expectSuite expectFn condStr
        , HigherOrderTests.expectSuite expectFn condStr
        , LetDestructTests.expectSuite expectFn condStr
        , LetRecTests.expectSuite expectFn condStr
        , LetTests.expectSuite expectFn condStr
        , ListTests.expectSuite expectFn condStr
        , LiteralTests.expectSuite expectFn condStr
        , MultiDefTests.expectSuite expectFn condStr
        , OperatorTests.expectSuite expectFn condStr
        , PatternArgTests.expectSuite expectFn condStr
        , RecordTests.expectSuite expectFn condStr
        , TupleTests.expectSuite expectFn condStr
        , DeepFuzzTests.expectSuite expectFn condStr

        --
        -- Kernel tests not from Source AST
        --, KernelTests.expectSuite expectFnCanonical condStr
        ]


typeCheckFailsSuite : Test
typeCheckFailsSuite =
    TypeCheckFails.expectSuite expectEquivalentTypeCheckingFails "Equivalent type checking failures"
