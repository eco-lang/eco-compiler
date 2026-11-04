module Compiler.Type.PostSolveGroupBTypesTest exposing (suite)

{-| Pins that every program of `SourceIR.GroupBLiteralCases` holds at least
one string, character or float literal or unit, so that the POST\_001 check
those programs were written for has something to look at in each.

The check itself, that PostSolve types each such literal with its form's type
in agreement with the solver, runs over the whole standard catalogue, these
programs included, as `TestLogic.Type.PostSolve.PostSolveGroupBStructuralTypesTest`.
Here each program is given to
`TestLogic.Type.PostSolve.GroupBTypes.expectGroupBTypesValid`, which runs the
same check and also fails on a program with no such literal.

-}

import SourceIR.GroupBLiteralCases as GroupBLiteralCases
import Test exposing (Test)
import TestLogic.Type.PostSolve.GroupBTypes exposing (expectGroupBTypesValid)


{-| The one test: `expectGroupBTypesValid` over the programs of
`SourceIR.GroupBLiteralCases`.
-}
suite : Test
suite =
    Test.describe "GroupB types are fully resolved (POST_001)"
        [ GroupBLiteralCases.expectSuite expectGroupBTypesValid "hold a literal and type it structurally"
        ]
