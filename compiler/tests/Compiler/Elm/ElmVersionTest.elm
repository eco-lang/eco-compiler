module Compiler.Elm.ElmVersionTest exposing (suite)

{-| Tests which Elm versions this compiler accepts in an `elm.json`: any 0.19.x
and no other. Without them, a project asking for a 0.19 release other than the
one the compiler implements could start being refused, or a 0.18 or 0.20 one
accepted, unnoticed.

Two functions make the check. `Version.isSupportedElm` takes one version, as an
application's `"elm-version"` gives it. `Constraint.goodElm` takes a range, as a
package's `"elm-version"` gives it, and is True when the range admits some
0.19.x. Both are pure, so the fixtures are just versions and constraints built
with `Constraint.untilNextMinor`, `untilNextMajor` and `exactly`.

What the tests establish:

  - `isSupportedElm` is True for 0.19.0, 0.19.1, 0.19.2 and 0.19.3, and False
    for 0.18.0, 0.20.0 and 1.19.1.
  - `goodElm` is True for `0.19.0 <= v < 0.20.0`, for constraints that leave
    out 0.19.1 (`0.19.2 <= v < 0.20.0`, exactly 0.19.3) and for one that runs
    past 0.19 (`0.19.2 <= v < 1.0.0`).
  - `goodElm` is False for `0.18.0 <= v < 0.19.0`, whose intersection with 0.19
    is the empty `0.19.0 <= v < 0.19.0`, for `0.20.0 <= v < 0.21.0`, and for
    exactly 0.18.0.

Among what is not tested: a range whose lower bound is exclusive, and the
`Builder` code that applies these checks to a project's `elm.json`.

-}

import Compiler.Elm.Constraint as Constraint
import Compiler.Elm.Version as V
import Expect
import Test exposing (Test)


{-| Returns the `isSupportedElm` tests, one per version, and the `goodElm`
tests, one per constraint, each comparing the result with the expected Bool.
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
