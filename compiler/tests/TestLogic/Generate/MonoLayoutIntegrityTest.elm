module TestLogic.Generate.MonoLayoutIntegrityTest exposing (suite)

{-| Test suite for invariants:

  - MONO\_006: Record and tuple layouts capture shape completely
  - MONO\_007: Record access matches layout metadata
  - MONO\_013: Constructor layouts define consistent custom types
  - MONO\_014: Structurally equivalent layouts are canonical

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Generate.MonoLayoutIntegrity
    exposing
        ( expectCtorLayoutsConsistent
        , expectLayoutsCanonical
        , expectRecordAccessMatchesLayout
        , expectRecordTupleLayoutsComplete
        )


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
        [ StandardTestSuites.expectSuite expectRecordTupleLayoutsComplete "has complete layouts"
        ]


recordAccessSuite : Test
recordAccessSuite =
    Test.describe "Record access matches layout (MONO_007)"
        [ StandardTestSuites.expectSuite expectRecordAccessMatchesLayout "has matching record access"
        ]


ctorLayoutsSuite : Test
ctorLayoutsSuite =
    Test.describe "Constructor layouts consistent (MONO_013)"
        [ StandardTestSuites.expectSuite expectCtorLayoutsConsistent "has consistent ctor layouts"
        ]


layoutCanonicalSuite : Test
layoutCanonicalSuite =
    Test.describe "Layouts are canonical (MONO_014)"
        [ StandardTestSuites.expectSuite expectLayoutsCanonical "has canonical layouts"
        ]
