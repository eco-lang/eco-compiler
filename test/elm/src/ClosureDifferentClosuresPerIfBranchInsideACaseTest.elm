module ClosureDifferentClosuresPerIfBranchInsideACaseTest exposing (..)

{-| Different closures per if branch inside a case.

From `SourceIR.ClosureCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 20

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


opClosure : Int -> Int -> Int
opClosure op =
    case op of
        n ->
            if n == 0 then
                \x -> x + 1

            else
                if n == 1 then
                    \x -> x * 2

                else
                    \x -> x


testValue : Int
testValue =
    opClosure 1 10


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
