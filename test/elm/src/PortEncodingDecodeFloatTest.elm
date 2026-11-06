port module PortEncodingDecodeFloatTest exposing (..)

{-| A port module declaring an incoming port that carries `Float` compiles and runs.

The port `inp` is declared but never subscribed to, so the compiler must still accept
`Float` as a type that can be decoded from JavaScript. `main` logs the constant `testValue`
and shows a text node, so the expected output is `testValue: 0`.

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


port inp : (Float -> msg) -> Sub msg


testValue =
    0


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
