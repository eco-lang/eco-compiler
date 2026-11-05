module CovMonoRefineSlotsSharingANumberVariableWithMaybeFunctionAndUnitPartsTest exposing (..)

{-| slots sharing a number variable with Maybe, function and unit parts.

From `SourceIR.CovMonoRefineCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 3.5

import Basics exposing (..)
import Bitwise exposing (..)
import Bytes exposing (..)
import Bytes.Decode exposing (..)
import Bytes.Encode exposing (..)
import Char exposing (..)
import List exposing (..)
import Maybe exposing (..)
import String exposing (..)
import Tuple exposing (..)
import Html


type T a
    = T ( Maybe a, a -> a, a ) ()


testValue : Float
testValue =
    let
        t =
            T ( Just 1, \v -> v, 2 ) ()

        (T ( m, f, n ) _) =
            t
    in
    n
        + f 0.5
        + (case m of
            Just z ->
                z

            Nothing ->
                0
          )


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
