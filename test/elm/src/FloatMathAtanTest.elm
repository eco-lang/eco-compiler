module FloatMathAtanTest exposing (..)

{-| `atan 0` is 0.
-}

-- CHECK: testValue: 0

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


testValue : Float
testValue =
    Basics.atan 0


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
