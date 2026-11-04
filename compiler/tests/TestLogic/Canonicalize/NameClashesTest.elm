module TestLogic.Canonicalize.NameClashesTest exposing (suite)

{-| Runs the name-clash oracle over the standard catalogue and the negative
catalogue, so that canonicalization accepting a name bound twice, or
rejecting a program that binds none twice, fails a test (CANON\_003).

`TestLogic.Canonicalize.NameClashes.expectNameClashesRejected` owns the check:
it reads the names the program binds itself and expects a `NAME CLASH` or
`SHADOWING` report, naming one of them, exactly when one is bound twice. The
programs with such a name are mostly those of `SourceIR.CanonicalizeFailsCases`;
every other program, of the standard catalogue, of the rest of the negative
catalogue and of `SourceIR.LimitBoundaryCases`, must get no such report.

-}

import SourceIR.LimitBoundaryCases as LimitBoundaryCases
import SourceIR.Suite.RejectedSuites as RejectedSuites
import SourceIR.Suite.StandardTestSuites as StandardTestSuites
import Test exposing (Test)
import TestLogic.Canonicalize.NameClashes exposing (expectNameClashesRejected)


{-| Both catalogues, each program checked by `expectNameClashesRejected`.
-}
suite : Test
suite =
    Test.describe "Names are bound once (CANON_003)"
        [ StandardTestSuites.expectSuite expectNameClashesRejected "has its names checked"
        , LimitBoundaryCases.expectSuite expectNameClashesRejected "has its names checked"
        , RejectedSuites.expectSuite (\_ program _ -> expectNameClashesRejected program) "has its names checked, though rejected"
        ]
