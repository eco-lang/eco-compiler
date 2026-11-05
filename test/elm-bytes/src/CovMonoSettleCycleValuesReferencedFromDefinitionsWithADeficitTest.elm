module CovMonoSettleCycleValuesReferencedFromDefinitionsWithADeficitTest exposing (..)

{-| cycle values referenced from definitions with a deficit.

From `SourceIR.CovMonoSettleCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 4

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


type alias Fn =
    Int -> Int


testValue : Int
testValue =
    step 0 1 + step 1 2


stepCall : Int -> Fn
stepCall k =
    case k of
        0 ->
            add k

        1 ->
            add (viaOther k)

        _ ->
            step (k - 1)


step : Int -> Fn
step k =
    case k of
        0 ->
            viaCall

        _ ->
            viaOther


viaOther : Fn
viaOther =
    stepCall 0


viaCall : Fn
viaCall =
    add 1


add : Int -> Int -> Int
add a b =
    a + b


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
