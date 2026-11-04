module TestLogic.GlobalOpt.LambdaIdUniquenessTest exposing (suite)

{-| `MONO_019`: within one `MonoGraph` no two `MonoClosure` nodes share a
`lambdaId`. Code generation names a nested closure's function after its
`lambdaId`, so a repeat would be two functions under one symbol.

`suite` gives every program that `SourceIR.Suite.StandardTestSuites` gathers
to `TestLogic.GlobalOpt.LambdaIdUniqueness.expectLambdaIdUniqueness`, which
checks the graph after monomorphization, after the global optimizer, and after
CAF hoisting run on that, and fails on any `lambdaId` found twice. The checker
itself is pinned on hand-built graphs by
`TestLogic.GlobalOpt.LambdaIdUniquenessCheckerTest`.

Among what is not tested: `ClosureInfo.srcLambda`, which may repeat by design;
programs outside the standard catalogue; graphs after CSE, which is off by
default.

-}

import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.GlobalOpt.LambdaIdUniqueness exposing (expectLambdaIdUniqueness)


{-| The `MONO_019` check over the standard catalogue.
-}
suite : Test
suite =
    Test.describe "LambdaId uniqueness (MONO_019)"
        [ StandardTestSuites.expectSuite expectLambdaIdUniqueness "has unique lambdaIds"
        ]
