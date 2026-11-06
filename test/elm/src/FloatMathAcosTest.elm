module FloatMathAcosTest exposing (..)

{-| `acos 1` is 0.

A Float that is a whole number is printed by `Debug.log` without a decimal point.

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
    Basics.acos 1


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
