port module PortEchoJsonValueTest exposing (main)

{-| A JSON `Value` sent out through a port comes back unchanged through an incoming
port, for each of four sample values.

The program assumes a host that passes every value sent out on the `echoOut`
port straight back in on the `echoIn` port; without one, nothing after `init`
is logged. It sends the values in `values` one at a time, sending the next only
after the previous one has come back, logs each value received as JSON text
from `Encode.encode 0`, logs `"done"` after the last one, and then drops its subscription.

The values are an object holding an array of mixed JSON values and a string, a
JSON string, a JSON number (2.5), and `null`.

-}

-- CHECK: PortEchoJsonValueTest got: "{\"a\":[1,true,null],\"b\":\"x\"}"
-- CHECK: PortEchoJsonValueTest got: "\"plain\""
-- CHECK: PortEchoJsonValueTest got: "2.5"
-- CHECK: PortEchoJsonValueTest got: "null"
-- CHECK: PortEchoJsonValueTest: "done"

import Json.Encode as Encode
import Platform


port echoOut : Encode.Value -> Cmd msg


port echoIn : (Encode.Value -> msg) -> Sub msg


values : List (Encode.Value)
values =
    [ Encode.object [ ( "a", Encode.list identity [ Encode.int 1, Encode.bool True, Encode.null ] ), ( "b", Encode.string "x" ) ]
    , Encode.string "plain"
    , Encode.float 2.5
    , Encode.null
    ]


type Msg
    = Got (Encode.Value)


type alias Model =
    { remaining : List (Encode.Value), done : Bool }


init : () -> ( Model, Cmd Msg )
init _ =
    case values of
        first :: rest ->
            ( { remaining = rest, done = False }, echoOut first )

        [] ->
            ( { remaining = [], done = True }, Cmd.none )


update : Msg -> Model -> ( Model, Cmd Msg )
update (Got v) model =
    let
        _ =
            Debug.log "PortEchoJsonValueTest got" (Encode.encode 0 v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoJsonValueTest" "done"
            in
            ( { model | done = True }, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.done then
        Sub.none

    else
        echoIn Got


main : Program () Model Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
