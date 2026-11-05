module CovMonoRefineATwoParameterFunctionFieldAndAnAliasFieldTest exposing (..)

{-| a two-parameter function field and an alias field.

From `SourceIR.CovMonoRefineCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 4.5

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


type W a
    = W (a -> a -> a) (Pair a) ( a, () )


type alias Pair a =
    ( a, a )


testValue : Float
testValue =
    let
        w =
            W (\a b -> a + b) ( 1, 2 ) ( 3, () )

        (W f ( p, _ ) ( q, _ )) =
            w
    in
    f 0.5 p + q


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
