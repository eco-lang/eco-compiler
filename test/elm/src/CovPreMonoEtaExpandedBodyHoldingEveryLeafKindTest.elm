module CovPreMonoEtaExpandedBodyHoldingEveryLeafKindTest exposing (..)

{-| eta-expanded body holding every leaf kind.

From `SourceIR.CovPreMonoCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 11

import Basics exposing (..)
import List exposing (..)
import Html


type Box
    = Box Int


type Color
    = Red
    | Green
    | Blue


type alias Fn =
    Int -> Int


testValue : Int
testValue =
    mk 3 4


mk : Int -> Fn
mk n =
    let
        h z =
            let
                go acc k =
                    if k <= 0 then
                        acc

                    else
                        go (acc + k) (k - 1)

                c =
                    'x'

                f =
                    1.5

                col =
                    Green

                b =
                    Box z
            in
            case ( col, b ) of
                ( Green, Box v ) ->
                    go v n + floor f

                _ ->
                    if c == 'x' then
                        0

                    else
                        1
    in
    h


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
