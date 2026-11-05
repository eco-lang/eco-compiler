module FloatMathAcosTest exposing (..)

{-| acos.

From `SourceIR.FloatMathCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

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
