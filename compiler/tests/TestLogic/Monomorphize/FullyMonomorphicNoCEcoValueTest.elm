module TestLogic.Monomorphize.FullyMonomorphicNoCEcoValueTest exposing (suite)

{-| Runs the check for type variables in the signatures of concrete
specializations over the standard catalogue of `SourceIR` test programs, so
that a specialization whose key type holds no type variable, but whose node
type, parameters or closure type still hold one, is looked for across many
programs rather than a hand-picked few.

The fixture is the set of programs gathered by
`SourceIR.Suite.StandardTestSuites.expectSuite`; this module adds none of its
own.

  - `suite` gives each program to
    `TestLogic.Monomorphize.FullyMonomorphicNoCEcoValue.expectFullyMonomorphicNoCEcoValue`.
    That check monomorphizes the program with the substitution engine and, in
    each specialization whose key type has no `MVar`, reports every `MVar`,
    `CEcoValue` or `CNumber`, in the node's type, its parameter types and the
    type of the closure it is. A program also fails when `runToMono` returns
    an error.

Among what is not tested: type variables inside a specialization's body, which
correct output does have (an unconstrained empty list or `let`-bound function;
the checker's module docstring gives the cases); specializations whose key type
still holds a type variable; and the solver engine, which is the default
engine of a build.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.FullyMonomorphicNoCEcoValue exposing (expectFullyMonomorphicNoCEcoValue)


{-| The unresolved-number-variable check applied to every program of the
standard catalogue, grouped under one `describe`.
-}
suite : Test
suite =
    Test.describe "MONO_024: Fully monomorphic specs have no type variable in their signature"
        [ StandardTestSuites.expectSuite expectFullyMonomorphicNoCEcoValue "has no type variable in fully monomorphic spec signatures"
        ]
