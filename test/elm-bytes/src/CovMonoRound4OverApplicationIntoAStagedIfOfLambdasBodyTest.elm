module CovMonoRound4OverApplicationIntoAStagedIfOfLambdasBodyTest exposing (..)

{-| over-application into a staged if-of-lambdas body.

From `SourceIR.CovMonoRound4Cases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 51

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
    useIt 1 + useIt -1 + pick 2 3 4 5


useIt : Int -> Int
useIt n =
    let
        h =
            pick n 2 3
    in
    h 4 + h 5


pick : Int -> Int -> Int -> Int -> Int
pick a =
    if a > 0 then
        \b c -> \d -> a * 3 + b * 5 + c * 7 + d * 11 + a * b * c * d + (a + b) * (c + d) + (a - b) * (c - d)

    else
        \b c -> \d -> a * 13 - b * 17 - c * 19 - d * 23 + a * b - c * d + (a - b) * (c + d) - (a + b) * (c - d)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
