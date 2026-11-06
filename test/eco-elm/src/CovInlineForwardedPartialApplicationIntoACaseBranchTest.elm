module CovInlineForwardedPartialApplicationIntoACaseBranchTest exposing (..)

{-| Checks a let-bound partial application that is used in only one branch of
the `case` that follows it: `testValue` is 10.

`choose` binds `g = add3 n` and calls `g 2 3` only for `Two`; the other two
branches do not use `g`. `choose One 1` is 0, `choose Two 2` is 7 and
`choose Three 3` is 3.

## eco

Taken from the program "Forwarded partial application into a case branch" in compiler/tests/SourceIR/CovInlineCases.elm, with a `main` that logs its `testValue`; the CHECK lines are what Elm 0.19.1 prints for it.

Exercises the inliner forwarding a let-bound partial application into the one `case` branch that uses it.

-}

-- CHECK: testValue: 10

import Basics exposing (..)
import Char exposing (Char)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple
import Html


type Kind
    = One
    | Two
    | Three


testValue : Int
testValue =
    choose One 1 + choose Two 2 + choose Three 3


choose : Kind -> Int -> Int
choose k n =
    let
        g =
            add3 n
    in
    case k of
        One ->
            0

        Two ->
            g 2 3

        Three ->
            n


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a * b + c


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
