module CompilerIssue2107PipeIfInfiniteTypeReportedTest exposing (main)

{-| A TYPE MISMATCH report shows an infinite type `Thing ∞` where no recursive type exists.

<https://github.com/elm/compiler/issues/2107>

The two `if` branches (`takesB : b -> Thing b -> Thing b` and `identity`) take different numbers
of arguments. Elm 0.19.1 reports that `(|>)` expects `Thing ∞ -> Thing ∞`; no type here is
infinite, so `∞` must not appear.

-}

-- COMPILE-ERROR: TYPE MISMATCH without an infinite type
-- CHECK: -- TYPE MISMATCH -
-- CHECK-NOT: ∞

import Html exposing (text)


type Thing b
    = Thing


takesB : b -> Thing b -> Thing b
takesB _ _ =
    Thing


foo =
    Thing
        |> (if True then
                takesB

            else
                identity
           )


main =
    text "done"
