module CovMonoRound4BranchesJoiningLambdasWithKernelOperatorsTest exposing (..)

{-| Functions that return a two-argument function from `if` and `case` branches mixing lambdas
with `(+)`, `(-)`, `min` and `max`, called fully, partially and through `List.foldl`, give 55.

The terms are 2, 7, -13, 54, 3 and 2. The `(-)` branch of `pickOp` and the `min` and `(-)`
branches of `pickIf` are not taken.

## eco

Exercises monomorphisation (`compiler/src/Compiler/Monomorphize/Solver/Engine.elm`) where
branches join lambdas with kernel operators, which then share one function representation.
From the catalogue `compiler/tests/SourceIR/CovMonoRound4Cases.elm`, which drives the
compiler front-end tests, with a `main` that logs its `testValue`; the CHECK lines are
what Elm 0.19.1 prints.

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


{-| Chooses a two-argument function by testing `sumTo n` in an `if` chain: `(+)` above 3,
`a * b - n` above 2, `min` above 1, otherwise `(-)`.
-}
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


{-| Chooses a two-argument function by a `case` on `sumTo n`: `a * b + n` for 0, `(+)` for 1,
`(-)` for 2, `a - b * n` for 6, otherwise `max`.
-}
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


{-| Sums 1 to `n`; 0 when `n` is not positive.
-}
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
