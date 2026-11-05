module ControlFlowBooleanWithNotTest exposing (..)

{-| Boolean with not.

From `SourceIR.ControlFlowCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: True

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


notPositive : Int -> Bool
notPositive n =
    not (n > 0)


testValue : Bool
testValue =
    notPositive -5


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
