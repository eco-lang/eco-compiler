module FloatMathSin2PlusCos21Test exposing (..)

{-| sin^2 + cos^2 = 1.

From `SourceIR.FloatMathCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

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
