port module CovPortIncomingTripleTest exposing (..)

{-| A port module declaring an incoming port whose values are an `( Int, String, Bool )` triple.

The program never subscribes to the port; the test checks that the declaration is accepted and
the program runs and logs `1`.

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


port inp : (( Int, String, Bool ) -> msg) -> Sub msg


testValue =
    1


main =
    let
        _ =
            Debug.log "testValue" testValue
    in
    Html.text "done"
