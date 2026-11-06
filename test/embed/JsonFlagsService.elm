port module JsonFlagsService exposing (main)

{-| The program `embed_host.js` drives in its `json-flags` scenarios, built both for the JS backend
and as a Node addon: its flags are any JSON value, which it sends straight back out on `flagsOut` at
start. It is a fixture, not an E2E test: it never ends on its own.
-}

import Json.Encode as Encode
import Platform


port flagsOut : Encode.Value -> Cmd msg


main : Program Encode.Value () ()
main =
    Platform.worker
        { init = \flags -> ( (), flagsOut flags )
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
