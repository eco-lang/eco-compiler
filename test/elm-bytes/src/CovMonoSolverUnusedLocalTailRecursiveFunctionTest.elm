module CovMonoSolverUnusedLocalTailRecursiveFunctionTest exposing (..)

{-| unused local tail-recursive function.

From `SourceIR.CovMonoSolverCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 8

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
        unused n acc =
            if n <= 0 then
                acc

            else
                unused (n - 1) (acc + n)

        used n acc =
            if n <= 0 then
                acc

            else
                used (n - 1) (acc * 2)
    in
    used 3 1


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
