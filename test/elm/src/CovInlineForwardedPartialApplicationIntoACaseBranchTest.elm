module CovInlineForwardedPartialApplicationIntoACaseBranchTest exposing (..)

{-| Forwarded partial application into a case branch.

From `SourceIR.CovInlineCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

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
