port module PortEncodingEncodeMaybeRecordTest exposing (..)

{-| A port module declaring an outgoing port that carries `Maybe { x : Int }` compiles and runs.

The port `out` is declared but never called, so the compiler must still accept `Maybe { x : Int }` as
a type that can be encoded to JavaScript. `main` logs the constant `testValue` and shows a
text node, so the expected output is `testValue: 0`.

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


port out : Maybe { x : Int } -> Cmd msg


testValue =
    0


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
