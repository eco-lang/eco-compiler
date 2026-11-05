module CovTailRecSplitATripleParameterTest exposing (..)

{-| Split a triple parameter.

From `SourceIR.CovTailRecCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: <function>

import Basics exposing (..)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Tuple
import Html


testValue k =
    rot k ( 1, 2, 3.0 )


rot : Int -> ( Int, Int, Float ) -> Float
rot n ( a, b, c ) =
    if n <= 0 then
        toFloat (a + b) + c

    else
        rot (n - 1) ( b, a + 1, c * 2.0 )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
