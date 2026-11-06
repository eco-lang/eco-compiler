module CompilerIssue2104IfBranchWrongTypeReportedTest exposing (main)

{-| The TYPE MISMATCH report for `if` branches with different numbers of arguments must show the
first branch's own type, not a type that neither branch has.

<https://github.com/elm/compiler/issues/2104>

The first branch `takesB` has type `b -> Thing a b -> Thing a b`. Elm 0.19.1 reports the previous
branches as `Thing a b -> Thing a (Thing a b) -> Thing a (Thing a b)`, a type polluted by the
failed unification with the second branch `takesString ""`.

-}

-- COMPILE-ERROR: TYPE MISMATCH that shows the first branch's real type
-- CHECK: -- TYPE MISMATCH -
-- CHECK-NOT: Thing a (Thing a b)

import Html exposing (text)


type Thing a b
    = Thing


takesB : b -> Thing a b -> Thing a b
takesB _ _ =
    Thing


takesString : String -> Thing a b -> Thing a b
takesString _ _ =
    Thing


foo =
    if True then
        takesB

    else
        takesString ""


main =
    text "done"
