module TestLogic.Monomorphize.MonoCtorLayoutIntegrityTest exposing (suite)

{-| Runs the constructor-shape check of
`TestLogic.Monomorphize.MonoCtorLayoutIntegrity` on every program in the
standard `SourceIR` catalogue, so that a monomorphized constructor node whose
shape is not the one listed for its own type, or a shape list that is not its
custom type's constructors, fails a test on any of those programs, not only on
a hand-picked few.

The fixture is the set of programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` hands to an expectation; that
module's docstring says which case modules it includes. Each program is
compiled to a monomorphized graph by `TestPipeline.runToMono`, which uses the
substitution engine.

What `suite` establishes, for each of those programs:

  - `runToMono` returns no error.
  - The shapes listed under each key of the graph's `ctorShapes` are the
    declared constructors of that custom type, in order, by name and field
    count, with distinct tags.
  - Every `MonoCtor` node's shape is listed under the custom type it
    constructs, with the same name, tag and field types (lambda-set
    annotations ignored).

Among what is not tested: the heap layout code generation derives from a
shape, any construction of or pattern match on a constructor inside an
expression, the solver engine, and the graph after global optimization.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.MonoCtorLayoutIntegrity exposing (expectMonoCtorLayoutIntegrity)


{-| The test group that applies `expectMonoCtorLayoutIntegrity` to every
program of the standard `SourceIR` catalogue.
-}
suite : Test
suite =
    Test.describe "MONO_013: Constructor layouts consistent"
        [ StandardTestSuites.expectSuite expectMonoCtorLayoutIntegrity "has consistent constructor layouts"
        ]
