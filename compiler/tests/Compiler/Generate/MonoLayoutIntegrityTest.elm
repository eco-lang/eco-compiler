module Compiler.Generate.MonoLayoutIntegrityTest exposing (suite)

{-| Test suite for invariants:

  - MONO_006: Record and tuple layouts capture shape completely
  - MONO_007: Record access matches layout metadata
  - MONO_013: Constructor layouts define consistent custom types
  - MONO_014: Structurally equivalent layouts are canonical

-}

import Compiler.Generate.MonoLayoutIntegrity
    exposing
        ( expectCtorLayoutsConsistent
        , expectLayoutsCanonical
        , expectRecordAccessMatchesLayout
        , expectRecordTupleLayoutsComplete
        )
import Compiler.StandardTestSuites as StandardTestSuites
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
