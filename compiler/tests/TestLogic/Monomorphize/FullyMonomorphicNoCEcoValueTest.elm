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
    `TestLogic.Monomorphize.FullyMonomorphicNoCEcoValue.expectFullyMonomorphicNoCEcoValue`,
    which monomorphizes it with the solver engine (`EngineSolver`, the
    default), and to `expectFullyMonomorphicNoCEcoValueSubst`, which uses the
    substitution engine (`EngineSubst`, bootstrap Stage 5). Under each engine
    the check reports, in each specialization whose key type has no `MVar`,
    every `MVar`, `CEcoValue` or `CNumber`, in the node's type, its parameter
    types and the type of the closure it is; and any registry key type that
    still holds a `CNumber` variable after Prune's closing (MONO\_028). A
    program also fails when monomorphization returns an error.

Among what is not tested: type variables inside a specialization's body, which
correct output does have (an unconstrained empty list or `let`-bound function;
the checker's module docstring gives the cases); and `CEcoValue` variables in
specializations whose key type still holds a type variable.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.FullyMonomorphicNoCEcoValue exposing (expectFullyMonomorphicNoCEcoValue, expectFullyMonomorphicNoCEcoValueSubst)


{-| The type-variable check applied to every program of the standard catalogue,
once per monomorphization engine.
-}
suite : Test
suite =
    Test.describe "MONO_024/MONO_028: Fully monomorphic specs have no type variable in their signature, and no number residual survives Prune"
        [ Test.describe "solver engine (EngineSolver)"
            [ StandardTestSuites.expectSuite expectFullyMonomorphicNoCEcoValue "has no type variable in fully monomorphic spec signatures (solver)"
            ]
        , Test.describe "substitution engine (EngineSubst)"
            [ StandardTestSuites.expectSuite expectFullyMonomorphicNoCEcoValueSubst "has no type variable in fully monomorphic spec signatures (subst)"
            ]
        ]
