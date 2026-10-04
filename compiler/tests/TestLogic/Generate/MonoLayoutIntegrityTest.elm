module TestLogic.Generate.MonoLayoutIntegrityTest exposing (suite)

{-| Runs the four layout checks of `TestLogic.Generate.MonoLayoutIntegrity` on
the standard catalogue of test programs, so that a monomorphized graph whose
record accesses name fields their record types lack, or whose constructor tags
are out of step with constructor order, fails a test on any of those programs,
not only on a hand-picked few.

The programs are the ones `SourceIR.Suite.StandardTestSuites.expectSuite`
gives to an expectation: the source programs built by each `SourceIR` case
module it includes. Every checker compiles a program with
`TestLogic.TestPipeline.runToMono`, which monomorphizes with the substitution
engine rather than the solver engine a default build uses, and stops before
global optimization. A _layout_ here is the shape a record, tuple or custom
type has in the graph; for a custom type it is the graph's `ctorShapes` entry,
the list of its constructors with their tags and field types.

What the tests establish, one group per checker, as
`TestLogic.Generate.MonoLayoutIntegrity` states each check in full:

  - `expectRecordTupleLayoutsComplete`: only that each program monomorphizes.
    The checker's only tests, for a record with a negative number of fields
    and a tuple with a negative number of elements, cannot fail.
  - `expectRecordAccessMatchesLayout`: each record access and record update
    the checker visits is applied to an expression whose type is a record
    with the named fields.
  - `expectCtorLayoutsConsistent`: in every `ctorShapes` entry, the
    constructor at position `i` of the list has tag `i`.
  - `expectLayoutsCanonical`: only that each program monomorphizes. The group
    is named for canonical layouts, but the checker inspects nothing in the
    graph.

Among what is not tested: programs from the `SourceIR` case modules that
`StandardTestSuites` leaves out; graphs built by the solver engine or after
global optimization; record accesses held inline in a case's decision tree;
constructor field counts and field types; and whether structurally equal
layouts are shared.

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
catalogue of programs. Each of its tests passes when its programs monomorphize.
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
programs. Each of its tests passes when its programs monomorphize.
-}
layoutCanonicalSuite : Test
layoutCanonicalSuite =
    Test.describe "Layouts are canonical (MONO_014)"
        [ StandardTestSuites.expectSuite expectLayoutsCanonical "has canonical layouts"
        ]
