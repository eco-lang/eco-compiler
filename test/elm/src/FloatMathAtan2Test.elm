module FloatMathAtan2Test exposing (..)

{-| `atan2 1 1` is pi/4, printed as 0.7853981633974483.
-}

-- CHECK: testValue: 0.7853981633974483

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


testValue : Float
testValue =
    Basics.atan2 1 1


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
