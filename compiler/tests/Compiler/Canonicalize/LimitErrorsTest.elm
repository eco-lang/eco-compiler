module Compiler.Canonicalize.LimitErrorsTest exposing (suite)

{-| Pins the numbers that the size limits of canonicalization are written
against: `Compiler.IR.Runtime.HeapLimits.maxCtorFields` is 2040 and
`maxRecordFields` is 2047 (HEAP_019).

The programs this module once held moved to the catalogues: those one over a
limit are cases of `SourceIR.LimitFailsCases`, whose `TOO MANY …` reports
`TestLogic.Reporting.ExpectedRejectionTest` checks, and those exactly at a
limit are `SourceIR.LimitBoundaryCases`. The size-limit oracle
(`TestLogic.Canonicalize.SizeLimitsTest`) runs on both, reading the sizes from
each program and the limits from `HeapLimits`, so it would follow a change of
the limits; this test is what fails when they change.

-}

import Compiler.IR.Runtime.HeapLimits as HeapLimits
import Expect
import Test exposing (Test)


{-| The whole suite.
-}
suite : Test
suite =
    Test.describe "Front-end limit diagnostics (B18, D5)"
        [ Test.test "the limits match HeapLimits" <|
            \_ ->
                Expect.equal ( HeapLimits.maxCtorFields, HeapLimits.maxRecordFields ) ( 2040, 2047 )
        ]
