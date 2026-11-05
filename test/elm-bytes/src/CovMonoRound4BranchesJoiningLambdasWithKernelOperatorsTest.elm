module CovMonoRound4BranchesJoiningLambdasWithKernelOperatorsTest exposing (..)

{-| branches joining lambdas with kernel operators.

From `SourceIR.CovMonoRound4Cases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 55

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
    let
        g =
            pickOp 3

        h =
            pickIf 2
    in
    pickOp 0 1 2 + pickOp 1 3 4 + g 5 6 + h 7 8 + pickIf 4 1 2 + List.foldl (pickOp 2) 0 [ 1, 2 ]


pickIf : Int -> Int -> Int -> Int
pickIf n =
    if sumTo n > 3 then
        (+)

    else if sumTo n > 2 then
        \a b -> a * b - n

    else if sumTo n > 1 then
        min

    else
        (-)


pickOp : Int -> Int -> Int -> Int
pickOp n =
    case sumTo n of
        0 ->
            \a b -> a * b + n

        1 ->
            (+)

        2 ->
            (-)

        6 ->
            \a -> \b -> a - b * n

        _ ->
            max


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
