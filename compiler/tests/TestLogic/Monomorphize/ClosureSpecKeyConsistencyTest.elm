module TestLogic.Monomorphize.ClosureSpecKeyConsistencyTest exposing (suite)

{-| Runs the closure and specialization-key consistency check over the
standard catalogue of `SourceIR` test programs, so that a function
specialization whose code disagrees with the type its registry entry records is
looked for across many programs rather than a hand-picked few.

The fixture is the set of programs gathered by
`SourceIR.Suite.StandardTestSuites.expectSuite`; this module adds none of its
own.

  - `suite` gives each program to
    `TestLogic.Monomorphize.ClosureSpecKeyConsistency.expectClosureSpecKeyConsistency`.
    That check monomorphizes the program with the substitution engine and, for
    each specialization implemented by a `MonoDefine` whose body is a
    `MonoClosure` or by a `MonoTailFunc`, compares the closure's parameter
    types and the type of its body with the specialization's key type, both
    flattened into one parameter list. Its module docstring gives the exact
    rules. A program also fails when `runToMono` returns an error.

Among what is not tested: closures nested inside a body, specializations whose
key type is not a function type beyond requiring that their closure take no
parameters, and the solver engine, which is the default engine of a build.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.ClosureSpecKeyConsistency exposing (expectClosureSpecKeyConsistency)


{-| The consistency check applied to every program of the standard catalogue,
grouped under one `describe`.
-}
suite : Test
suite =
    Test.describe "MONO_025: Closure MonoType matches specialization key"
        [ StandardTestSuites.expectSuite expectClosureSpecKeyConsistency "has closure types matching spec keys"
        ]
