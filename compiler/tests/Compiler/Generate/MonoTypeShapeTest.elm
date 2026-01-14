module Compiler.Generate.MonoTypeShapeTest exposing (suite)

{-| Test suite for invariant MONO_001: MonoType encodes fully elaborated runtime shapes.

-}

import Compiler.AST.Source as Src
import Compiler.AnnotatedTests as AnnotatedTests
import Compiler.CaseTests as CaseTests
import Compiler.FunctionTests as FunctionTests
import Compiler.Generate.MonoTypeShape exposing (expectMonoTypesFullyElaborated)
import Compiler.HigherOrderTests as HigherOrderTests
import Compiler.ListTests as ListTests
import Compiler.RecordTests as RecordTests
import Compiler.TupleTests as TupleTests
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MonoType encodes fully elaborated runtime shapes (MONO_001)"
        [ expectSuite expectMonoTypesFullyElaborated "has fully elaborated MonoTypes"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ AnnotatedTests.expectSuite expectFn condStr
        , CaseTests.expectSuite expectFn condStr
        , FunctionTests.expectSuite expectFn condStr
        , HigherOrderTests.expectSuite expectFn condStr
        , ListTests.expectSuite expectFn condStr
        , RecordTests.expectSuite expectFn condStr
        , TupleTests.expectSuite expectFn condStr
        ]
