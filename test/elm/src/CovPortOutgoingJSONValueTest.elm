port module CovPortOutgoingJSONValueTest exposing (..)

{-| A port module declaring an outgoing port that sends a `Json.Encode.Value`.

The program never sends on the port; the test checks that the declaration is accepted and the
program runs and logs `1`.

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


port out : Json.Encode.Value -> Cmd msg


testValue =
    1


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
