module TestLogic.Generate.MonoLayoutIntegrityTest exposing (suite)

{-| Runs the four layout checks of `TestLogic.Generate.MonoLayoutIntegrity` on
the standard catalogue of test programs, so that a monomorphized graph whose
record and tuple constructions do not match their types, whose record accesses
name fields their record types lack, whose constructor tags are out of step
with constructor order, or whose record and tuple types carry stale hashes,
fails a test on any of those programs, not only on a hand-picked few.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gives to an expectation: the source programs built by each `SourceIR` case
module it includes. Every checker compiles a program with
`TestLogic.TestPipeline.runToMono`, the production pipeline, which stops
before global optimization. A _layout_ here is the shape a record, tuple or custom
type has in the graph; for a custom type it is the graph's `ctorShapes` entry,
the list of its constructors with their tags and field types.

What the tests establish, one group per checker, as
`TestLogic.Generate.MonoLayoutIntegrity` states each check in full:

  - `expectRecordTupleLayoutsComplete`: every record creation names exactly
    its type's fields, every tuple creation matches its tuple type, every
    record update keeps its record's type, and every tuple type has 2 or 3
    elements.
  - `expectRecordAccessMatchesLayout`: each record access and record update
    is applied to an expression whose type is a record with the named fields,
    and an access has its field's type.
  - `expectCtorLayoutsConsistent`: in every `ctorShapes` entry, each
    constructor's tag is the one `CtorTag.effective` gives its position.
  - `expectLayoutsCanonical`: every record and tuple type carries the packed
    hash its structure gives.

Every expression is visited, including those a case holds inline in its
decision tree.

Among what is not tested: programs from the `SourceIR` case modules that
`StandardTestSuites` leaves out; graphs built by the solver engine or after
global optimization; and constructor field counts and field types.

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


{-| The four groups of tests listed above, one per checker.
-}
suite : Test
suite =
    Test.describe "Layout integrity in monomorphization"
        [ recordTupleLayoutsSuite
        , recordAccessSuite
        , ctorLayoutsSuite
        , layoutCanonicalSuite
        ]


{-| The group running `expectRecordTupleLayoutsComplete` over the standard
catalogue of programs.
-}
recordTupleLayoutsSuite : Test
recordTupleLayoutsSuite =
    Test.describe "Record/tuple layouts complete (MONO_006)"
        [ StandardTestSuites.expectSuite expectRecordTupleLayoutsComplete "has complete layouts"
        ]


{-| The group running `expectRecordAccessMatchesLayout` over the standard
catalogue of programs.
-}
recordAccessSuite : Test
recordAccessSuite =
    Test.describe "Record access matches layout (MONO_007)"
        [ StandardTestSuites.expectSuite expectRecordAccessMatchesLayout "has matching record access"
        ]


{-| The group running `expectCtorLayoutsConsistent` over the standard catalogue
of programs.
-}
ctorLayoutsSuite : Test
ctorLayoutsSuite =
    Test.describe "Constructor layouts consistent (MONO_013)"
        [ StandardTestSuites.expectSuite expectCtorLayoutsConsistent "has consistent ctor layouts"
        ]


{-| The group running `expectLayoutsCanonical` over the standard catalogue of
programs.
-}
layoutCanonicalSuite : Test
layoutCanonicalSuite =
    Test.describe "Layouts are canonical (MONO_014)"
        [ StandardTestSuites.expectSuite expectLayoutsCanonical "has canonical layouts"
        ]
