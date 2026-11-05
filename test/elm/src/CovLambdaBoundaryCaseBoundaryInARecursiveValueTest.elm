module CovLambdaBoundaryCaseBoundaryInARecursiveValueTest exposing (..)

{-| Case boundary in a recursive value.

From `SourceIR.CovLambdaBoundaryCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 4

import Basics exposing (..)
import Char exposing (Char)
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple
import Html


testValue : Int
testValue =
    pickV 0 3


pickV : Int -> Int -> Int
pickV =
    \n ->
        case n of
            0 ->
                \a ->
                    if a > 10 then
                        pickV 1 a

                    else
                        a + 1

            _ ->
                \b -> b


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
