module TestLogic.Monomorphize.LocalUseEnrichmentTest exposing (suite)

{-| Tests, on the standard catalogue of test programs, that after
monomorphization by the solver engine with lambda-set specialization on, each
use of a let-bound name carries the lambda-set annotations of the definition
it refers to (E4a use enrichment).

Each program `SourceIR.Suite.StandardTestSuites.expectSuite` supplies is given
to `TestLogic.Monomorphize.LocalUseEnrichment.expectLocalUsesEnriched`, which
monomorphizes it with `TestLogic.TestPipeline.runToMono` and fails on a use
`MonoVarLocal n t` in the body of a `let` defining `MonoDef n rhs` whose type
changes when the definition's annotations are copied onto it. A program that
fails to monomorphize fails.

The catalogue includes `SourceIR.LocalMultiEnrichCases`, the nesting shapes
this check was first written for.

Among what is not tested: the substitution engine; whether the sets are the
right ones; uses of a name inside its own right-hand side; and names bound by a
`MonoTailDef` or by destructuring.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.LocalUseEnrichment exposing (expectLocalUsesEnriched)


{-| `expectLocalUsesEnriched` over every program of the standard catalogue.
-}
suite : Test
suite =
    Test.describe "Local let-function uses carry their definition's lambda sets"
        [ StandardTestSuites.expectSuite expectLocalUsesEnriched "has enriched local uses"
        ]
