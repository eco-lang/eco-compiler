module CovMonoRound4LocalsBoundToValuesDefinedByIfAndCaseTest exposing (..)

{-| locals bound to values defined by if and case.

From `SourceIR.CovMonoRound4Cases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 7520

import Basics exposing (..)
import Bitwise exposing (..)
import Bytes exposing (..)
import Bytes.Decode exposing (..)
import Bytes.Encode exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Tuple exposing (..)
import Html


testValue : Int
testValue =
    useBoth 1 + useBoth 2


useBoth : Int -> Int
useBoth k =
    let
        a =
            cafIf

        b =
            cafCase
    in
    a * k + b * a + b * k + a * b * k


cafCase : Int
cafCase =
    case cafIf of
        3 ->
            sumTo 7 + sumTo 8 * 13

        _ ->
            sumTo 9 - sumTo 1 * 17


cafIf : Int
cafIf =
    if sumTo 10 > 20 then
        sumTo 3 * 7 + sumTo 4

    else
        sumTo 5 - sumTo 6 * 11


sumTo : Int -> Int
sumTo n =
    if n <= 0 then
        0

    else
        n + sumTo (n - 1)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
