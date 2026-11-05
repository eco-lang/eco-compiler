module CovMonoRound4TailFunctionsWhoseTailCallFoldsAwayTest exposing (..)

{-| tail functions whose tail call folds away.

From `SourceIR.CovMonoRound4Cases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 40

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
    loopIf 3 4 + loopCase 5 6
        + (let
            g =
                loopIf 1
           in
           g 2
          )


loopCase : Int -> Int -> Int
loopCase n =
    case True of
        True ->
            \x -> x * n

        False ->
            loopCase (n + 1)


loopIf : Int -> Int -> Int
loopIf n =
    if False then
        loopIf (n - 1)

    else
        \x -> x + n


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
