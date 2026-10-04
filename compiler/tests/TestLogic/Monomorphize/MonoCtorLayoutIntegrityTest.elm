module TestLogic.Monomorphize.MonoCtorLayoutIntegrityTest exposing (suite)

{-| Runs the constructor-shape check of
`TestLogic.Monomorphize.MonoCtorLayoutIntegrity` on every program in the
standard `SourceIR` catalogue, so that a monomorphized constructor node whose
name and tag are missing from the graph's table of constructor shapes fails a
test on any of those programs, not only on a hand-picked few.

The fixture is the set of programs that
`SourceIR.Suite.StandardTestSuites.expectSuite` hands to an expectation; that
module's docstring says which case modules it includes. Each program is
compiled to a monomorphized graph by `TestPipeline.runToMono`, which uses the
substitution engine.

What `suite` establishes, for each of those programs:

  - `runToMono` returns no error.
  - Every `MonoCtor` node's shape has the name and tag of some shape in the
    graph's `ctorShapes`, under any type key; field types are not compared.
  - Every shape in `ctorShapes`, given to `Types.computeCtorLayout`, yields a
    layout with one field per field type that marks only `Int`, `Float` and
    `Char` fields unboxed. As the checker's docstring notes, these two layout
    checks cannot fail while `computeCtorLayout` stays as it is.

Among what is not tested: the order of a layout's fields, its unboxed bitmap,
whether a shape agrees with the constructor's source definition, any
construction of or pattern match on a constructor inside an expression, the
solver engine, and the graph after global optimization.

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
