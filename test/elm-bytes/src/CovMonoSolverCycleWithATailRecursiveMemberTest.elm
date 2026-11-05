module CovMonoSolverCycleWithATailRecursiveMemberTest exposing (..)

{-| cycle with a tail-recursive member.

From `SourceIR.CovMonoSolverCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 20

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


type alias Fn =
    Int -> Int


testValue : Int
testValue =
    countDown 5 0 + loopFn 2 3


other : Int -> Int
other x =
    if x > 10 then
        loopFn 0 (x - 10)

    else
        x


loopFn : Int -> Fn
loopFn n x =
    if n <= 0 then
        other x

    else
        loopFn (n - 1) (x + 1)


finish : Int -> Int
finish acc =
    if acc > 100 then
        countDown 1 (acc - 100)

    else
        acc


countDown : Int -> Int -> Int
countDown n acc =
    if n <= 0 then
        finish acc

    else
        countDown (n - 1) (acc + n)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
