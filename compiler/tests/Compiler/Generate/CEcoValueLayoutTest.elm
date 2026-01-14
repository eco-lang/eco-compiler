module Compiler.Generate.CEcoValueLayoutTest exposing (suite)

{-| Test suite for invariant MONO_003: CEcoValue layout is consistent.

-}

import Compiler.AST.Source as Src
import Compiler.AST.SourceBuilder as SB
import Compiler.CaseTests as CaseTests
import Compiler.FunctionTests as FunctionTests
import Compiler.Generate.CEcoValueLayout exposing (expectValidCEcoValueLayout)
import Compiler.ListTests as ListTests
import Compiler.RecordTests as RecordTests
import Compiler.TupleTests as TupleTests
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "CEcoValue layout is consistent (MONO_003)"
        [ expectSuite expectValidCEcoValueLayout "has valid CEcoValue layout"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ FunctionTests.expectSuite expectFn condStr
        , ListTests.expectSuite expectFn condStr
        , RecordTests.expectSuite expectFn condStr
        , TupleTests.expectSuite expectFn condStr
        , CaseTests.expectSuite expectFn condStr
        ]
