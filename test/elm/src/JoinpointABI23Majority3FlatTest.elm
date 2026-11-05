module JoinpointABI23Majority3FlatTest exposing (..)

{-| 2.3 majority3Flat.

From `SourceIR.JoinpointABICases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 10

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


caseFunc : Int -> Int -> Int -> Int -> Int
caseFunc x =
    case x of
        0 ->
            \a b c -> a + b + c

        1 ->
            \a b c -> a - b - c

        2 ->
            \a b c -> a * b * c

        _ ->
            \a -> \b -> \c -> a + b - c


testValue : Int
testValue =
    caseFunc 0 5 3 2


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
