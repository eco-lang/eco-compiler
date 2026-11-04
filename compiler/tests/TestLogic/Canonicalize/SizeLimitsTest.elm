module TestLogic.Canonicalize.SizeLimitsTest exposing (suite)

{-| Runs the size-limit oracle over the standard catalogue and the negative
catalogue, so that canonicalization rejecting a function, closure, constructor
or record within the runtime's limits, or accepting one over them, fails a
test (HEAP\_019, HEAP\_078).

`TestLogic.Canonicalize.SizeLimits.expectSizeLimitsEnforced` owns the check:
it reads the program's sizes itself and expects a `TOO MANY …` report exactly
when one is over its limit. The programs over a limit are those of
`SourceIR.LimitFailsCases`; the standard catalogue's programs and the rest of
the negative catalogue must get no such report. The at-limit programs of
`SourceIR.LimitBoundaryCases`, which no other suite runs, show that a size
exactly at a limit is accepted.

Among what is not tested: limits that only show after specialization
(`Compiler.Monomorphize.ValidateLimits`), whose programs are in
`SourceIR.MonoFailsCases` and get no canonicalization report.

-}

import SourceIR.LimitBoundaryCases as LimitBoundaryCases
import SourceIR.Suite.RejectedSuites as RejectedSuites
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Canonicalize.SizeLimits exposing (expectSizeLimitsEnforced)


{-| Both catalogues, each program checked by `expectSizeLimitsEnforced`.
-}
suite : Test
suite =
    Test.describe "Size limits are enforced exactly (HEAP_019, HEAP_078)"
        [ StandardTestSuites.expectSuite expectSizeLimitsEnforced "has its sizes checked"
        , LimitBoundaryCases.expectSuite expectSizeLimitsEnforced "has its sizes checked"
        , RejectedSuites.expectSuite (\_ program _ -> expectSizeLimitsEnforced program) "has its sizes checked, though rejected"
        ]
