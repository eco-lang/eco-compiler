module Compiler.Generate.MonoLayoutIntegrityTest exposing (suite)

{-| Test suite for invariants:

  - MONO_006: Record and tuple layouts capture shape completely
  - MONO_007: Record access matches layout metadata
  - MONO_013: Constructor layouts define consistent custom types
  - MONO_014: Structurally equivalent layouts are canonical

-}

import Compiler.AST.Source as Src
import Compiler.Generate.MonoLayoutIntegrity exposing
    ( expectCtorLayoutsConsistent
    , expectLayoutsCanonical
    , expectRecordAccessMatchesLayout
    , expectRecordTupleLayoutsComplete
    )
import Compiler.LetTests as LetTests
import Compiler.MultiDefTests as MultiDefTests
import Compiler.RecordTests as RecordTests
import Expect exposing (Expectation)
import Test exposing (Test)


suite : Test
suite =
    Test.describe "Layout integrity in monomorphization"
        [ recordTupleLayoutsSuite
        , recordAccessSuite
        , ctorLayoutsSuite
        , layoutCanonicalSuite
        ]


recordTupleLayoutsSuite : Test
recordTupleLayoutsSuite =
    Test.describe "Record/tuple layouts complete (MONO_006)"
        [ expectSuite expectRecordTupleLayoutsComplete "has complete layouts"
        ]


recordAccessSuite : Test
recordAccessSuite =
    Test.describe "Record access matches layout (MONO_007)"
        [ expectSuite expectRecordAccessMatchesLayout "has matching record access"
        ]


ctorLayoutsSuite : Test
ctorLayoutsSuite =
    Test.describe "Constructor layouts consistent (MONO_013)"
        [ expectSuite expectCtorLayoutsConsistent "has consistent ctor layouts"
        ]


layoutCanonicalSuite : Test
layoutCanonicalSuite =
    Test.describe "Layouts are canonical (MONO_014)"
        [ expectSuite expectLayoutsCanonical "has canonical layouts"
        ]


expectSuite : (Src.Module -> Expectation) -> String -> Test
expectSuite expectFn condStr =
    Test.describe condStr
        [ RecordTests.expectSuite expectFn condStr
        , LetTests.expectSuite expectFn condStr
        , MultiDefTests.expectSuite expectFn condStr
        ]
