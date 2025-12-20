module Compiler.Canonicalize.IdAssignmentTest exposing (suite)

{-| Consolidated test suite for ID assignment verification.

This module gathers all individual test suites and runs them with the
appropriate expectation functions.

-}

import Compiler.AST.Canonical as Can
import Compiler.AST.Source as Src
import Compiler.AsPatternTests as AsPatternTests
import Compiler.BinopTests as BinopTests
import Compiler.Canonicalize.IdAssignment exposing (expectUniqueIds, expectUniqueIdsCanonical)
import Compiler.CaseTests as CaseTests
import Compiler.DeepFuzzTests as DeepFuzzTests
import Compiler.EdgeCaseTests as EdgeCaseTests
import Compiler.FunctionTests as FunctionTests
import Compiler.HigherOrderTests as HigherOrderTests
import Compiler.KernelTests as KernelTests
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
import Compiler.TypeCheckFails as TypeCheckFails
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    expectSuite expectUniqueIds expectUniqueIdsCanonical "has unique IDs"


expectSuite : (Src.Module -> Expectation) -> (Can.Module -> Expectation) -> String -> Test
expectSuite expectFn expectFnCanonical condStr =
    Test.describe "Unique IDs for all nodes in Canonical form"
        [ AsPatternTests.expectSuite expectFn condStr
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

        -- Type check fails but canonicalization should not.
        , TypeCheckFails.expectSuite expectFn condStr

        -- Kernel functions already in canonical form - it make not sense to check for unique ids?
        , KernelTests.expectSuite expectFnCanonical condStr
        ]
