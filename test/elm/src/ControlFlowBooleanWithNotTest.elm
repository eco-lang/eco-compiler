module ControlFlowBooleanWithNotTest exposing (..)

{-| Checks `not` applied to a comparison: `not (n > 0)` for `n = -5` is `True`.
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
