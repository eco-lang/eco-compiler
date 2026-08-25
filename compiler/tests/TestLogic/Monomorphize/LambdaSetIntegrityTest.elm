module TestLogic.Monomorphize.LambdaSetIntegrityTest exposing (suite)

{-| Test suite for invariant LSS\_002: lambda-set lowering totality.
-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Monomorphize.LambdaSetIntegrity exposing (expectLambdaSetIntegrity, expectLambdaSetIntegrityArrowId)


suite : Test
suite =
    Test.describe "Lambda set integrity (LSS_002)"
        [ StandardTestSuites.expectSuite expectLambdaSetIntegrity "satisfies LSS_002"

        -- Phase 2a (plans/lss-unknown-elimination.md §4): the SAME corpus with
        -- `lss.arrowIdentity` ON. Slot sharing's plausible failure mode is a
        -- LOST member, which is precisely what LSS_002 catches; the flag ships
        -- default-off, so without this arm the arrow-memo path has no
        -- whole-pipeline coverage at all.
        , StandardTestSuites.expectSuite expectLambdaSetIntegrityArrowId "satisfies LSS_002 under lss.arrowIdentity"
        ]
