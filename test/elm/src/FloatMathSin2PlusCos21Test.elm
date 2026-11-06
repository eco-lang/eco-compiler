module FloatMathSin2PlusCos21Test exposing (..)

{-| `sin 1 * sin 1 + cos 1 * cos 1` prints as exactly 1.

The sum is computed by a top-level function, `pythagorean`, applied to 1.

-}

-- CHECK: testValue: 1

import Basics exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Html


pythagorean : Float -> Float
pythagorean x =
    (Basics.sin x * Basics.sin x) + (Basics.cos x * Basics.cos x)


testValue : Float
testValue =
    pythagorean 1


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
