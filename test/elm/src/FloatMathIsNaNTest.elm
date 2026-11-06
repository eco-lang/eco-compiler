module FloatMathIsNaNTest exposing (..)

{-| `isNaN (0 / 0)` is True.
-}

-- CHECK: testValue: True

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


testValue : Bool
testValue =
    Basics.isNaN (0 / 0)


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
