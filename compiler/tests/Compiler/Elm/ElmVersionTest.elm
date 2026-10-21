module Compiler.Elm.ElmVersionTest exposing (suite)

{-| Tests which Elm versions this compiler builds a project for: every 0.19.x,
and no other (plans/accept-any-elm-0-19.md).

`Version.isSupportedElm` is the check on an application's `"elm-version"`, and
`Constraint.goodElm` the one on a package's `"elm-version"` constraint, which
the dependency solver also applies to every candidate package.

What the tests establish:

  - `isSupportedElm` is True for 0.19.0, 0.19.1, 0.19.2 and 0.19.3, and False
    for 0.18.0, 0.20.0 and 1.19.1.
  - `goodElm` is True for `0.19.0 <= v < 0.20.0`, for constraints that leave
    out 0.19.1 (`0.19.2 <= v < 0.20.0`, exactly 0.19.3) and for one that runs
    past 0.19 (`0.19.2 <= v < 1.0.0`).
  - `goodElm` is False for `0.18.0 <= v < 0.19.0`, whose intersection with 0.19
    is the empty `0.19.0 <= v < 0.19.0`, for `0.20.0 <= v < 0.21.0`, and for
    exactly 0.18.0.

-}

import Compiler.Elm.Constraint as Constraint
import Compiler.Elm.Version as V
import Expect
import Test exposing (Test)


{-| The `isSupportedElm` and `goodElm` tests.
-}
suite : Test
suite =
    Test.describe "Supported Elm versions"
        [ Test.describe "isSupportedElm"
            (List.map
                (\( version, expected ) ->
                    Test.test (V.toChars version) <|
                        \_ ->
                            V.isSupportedElm version
                                |> Expect.equal expected
                )
                [ ( V.Version 0 19 0, True )
                , ( V.Version 0 19 1, True )
                , ( V.Version 0 19 2, True )
                , ( V.Version 0 19 3, True )
                , ( V.Version 0 18 0, False )
                , ( V.Version 0 20 0, False )
                , ( V.Version 1 19 1, False )
                ]
            )
        , Test.describe "goodElm"
            (List.map
                (\( constraint, expected ) ->
                    Test.test (Constraint.toChars constraint) <|
                        \_ ->
                            Constraint.goodElm constraint
                                |> Expect.equal expected
                )
                [ ( Constraint.untilNextMinor (V.Version 0 19 0), True )
                , ( Constraint.untilNextMinor (V.Version 0 19 2), True )
                , ( Constraint.exactly (V.Version 0 19 3), True )
                , ( Constraint.untilNextMajor (V.Version 0 19 2), True )
                , ( Constraint.untilNextMinor (V.Version 0 18 0), False )
                , ( Constraint.untilNextMinor (V.Version 0 20 0), False )
                , ( Constraint.exactly (V.Version 0 18 0), False )
                ]
            )
        ]
