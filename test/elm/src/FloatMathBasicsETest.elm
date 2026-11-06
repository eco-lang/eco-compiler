module FloatMathBasicsETest exposing (..)

{-| `Basics.e` prints as 2.718281828459045.
-}

-- CHECK: testValue: 2.718281828459045

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


testValue : Float
testValue =
    Basics.e


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
