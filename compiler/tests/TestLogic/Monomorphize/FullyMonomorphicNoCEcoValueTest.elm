module TestLogic.Monomorphize.FullyMonomorphicNoCEcoValueTest exposing (suite)

{-| Runs the check for unresolved number variables in concrete
specializations over the standard catalogue of `SourceIR` test programs, so
that a specialization whose key type holds no type variable, but whose node or
body still holds one known only to be a number, is looked for across many
programs rather than a hand-picked few.

The fixture is the set of programs gathered by
`SourceIR.Suite.StandardTestSuites.expectSuite`; this module adds none of its
own.

  - `suite` gives each program to
    `TestLogic.Monomorphize.FullyMonomorphicNoCEcoValue.expectFullyMonomorphicNoCEcoValue`.
    That check monomorphizes the program with the substitution engine and, in
    each specialization whose key type has no `MVar`, reports every
    `MVar _ CNumber` in the types it walks. Despite the name, an
    `MVar _ CEcoValue` is accepted. A program also fails when `runToMono`
    returns an error.

As the checker's module docstring explains, the substitution engine's pruning
already turns every number variable it finds into `Int` and crashes if one
survives, so on these programs the check is not expected to report anything: a
program that compiles passes, and an unresolved number variable shows up as a
crash.

Among what is not tested: specializations whose key type still holds a type
variable, the positions the checker does not walk, and the solver engine, which
is the default engine of a build.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.FullyMonomorphicNoCEcoValue exposing (expectFullyMonomorphicNoCEcoValue)


{-| The unresolved-number-variable check applied to every program of the
standard catalogue, grouped under one `describe`.
-}
suite : Test
suite =
    Test.describe "MONO_024: Fully monomorphic specs have no CEcoValue"
        [ StandardTestSuites.expectSuite expectFullyMonomorphicNoCEcoValue "has no CEcoValue in fully monomorphic specs"
        ]
