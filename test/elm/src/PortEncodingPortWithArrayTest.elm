port module PortEncodingPortWithArrayTest exposing (..)

{-| Port with Array.

From `SourceIR.PortEncodingCases`, a program of the elm-test catalogue, with a
`main` that logs its `testValue`. The CHECK lines are what Elm 0.19.1 prints for it.

-}

-- CHECK: testValue: 0

import Array exposing (..)
import Basics exposing (..)
import Char exposing (..)
import Json.Decode exposing (..)
import Json.Encode exposing (..)
import List exposing (..)
import Maybe exposing (..)
import Platform.Cmd exposing (..)
import Platform.Sub exposing (..)
import String exposing (..)
import Html


port out : Array Int -> Cmd msg


testValue =
    0


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
