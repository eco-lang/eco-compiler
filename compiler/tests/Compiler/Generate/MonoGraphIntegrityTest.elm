module Compiler.Generate.MonoGraphIntegrityTest exposing (suite)

{-| Test suite for MonoGraph integrity invariants:

  - MONO_004: All functions are callable MonoNodes
  - MONO_005: Specialization registry is complete and consistent
  - MONO_010: MonoGraph is type complete
  - MONO_011: MonoGraph is closed and hygienic

-}

import Compiler.AST.Source as Src
import Compiler.AnnotatedTests as AnnotatedTests
import Compiler.CaseTests as CaseTests
import Compiler.FunctionTests as FunctionTests
import Compiler.Generate.MonoGraphIntegrity exposing
    ( expectCallableMonoNodes
    , expectMonoGraphComplete
    , expectMonoGraphClosed
    , expectSpecRegistryComplete
    )
import Compiler.HigherOrderTests as HigherOrderTests
import Compiler.LetRecTests as LetRecTests
import Compiler.LetTests as LetTests
import Compiler.ListTests as ListTests
import Compiler.RecordTests as RecordTests
import Compiler.TupleTests as TupleTests
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "MonoGraph integrity invariants"
        [ Test.describe "MONO_004: All functions are callable MonoNodes"
            [ expectSuite expectCallableMonoNodes "has callable function nodes"
            ]
        , Test.describe "MONO_005: Specialization registry is complete"
            [ expectSuite expectSpecRegistryComplete "has complete registry"
            ]
        , Test.describe "MONO_010: MonoGraph is type complete"
            [ expectSuite expectMonoGraphComplete "is type complete"
            ]
        , Test.describe "MONO_011: MonoGraph is closed and hygienic"
            [ expectSuite expectMonoGraphClosed "is closed"
            ]
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ AnnotatedTests.expectSuite expectFn condStr
        , CaseTests.expectSuite expectFn condStr
        , FunctionTests.expectSuite expectFn condStr
        , HigherOrderTests.expectSuite expectFn condStr
        , LetRecTests.expectSuite expectFn condStr
        , LetTests.expectSuite expectFn condStr
        , ListTests.expectSuite expectFn condStr
        , RecordTests.expectSuite expectFn condStr
        , TupleTests.expectSuite expectFn condStr
        ]
