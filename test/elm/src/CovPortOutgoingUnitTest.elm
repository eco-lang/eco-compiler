port module CovPortOutgoingUnitTest exposing (..)

{-| Outgoing unit.

From `SourceIR.CovPortCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 1

import Array
import Basics exposing (..)
import Bytes
import Char exposing (Char)
import Json.Decode
import Json.Encode
import List exposing ((::))
import Maybe exposing (Maybe(..))
import Platform.Cmd as Cmd exposing (Cmd)
import Platform.Sub as Sub exposing (Sub)
import String exposing (String)
import Tuple
import Html


type alias Point =
    { x : Int }


port out : () -> Cmd msg


testValue =
    1


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
