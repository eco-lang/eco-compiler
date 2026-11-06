port module PortEchoTest exposing (main)

{-| An `Int` sent out through an outgoing port comes back unchanged through an incoming port.

The test host must feed every payload of the outgoing port `echoOut` back into the incoming
port `echoIn`. `init` sends `42`; `update` logs the received value, then a `done` line, and
marks the model as received, after which `subscriptions` returns `Sub.none` so the
program can finish.

-}

-- CHECK: PortEchoTest got: 42
-- CHECK: PortEchoTest done: "ok"

import Platform


port echoOut : Int -> Cmd msg


port echoIn : (Int -> msg) -> Sub msg


type Msg
    = Got Int


type alias Model =
    { received : Bool }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { received = False }, echoOut 42 )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Got n ->
            let
                _ =
                    Debug.log "PortEchoTest got" n

                _ =
                    Debug.log "PortEchoTest done" "ok"
            in
            ( { model | received = True }, Cmd.none )


subscriptions : Model -> Sub Msg
subscriptions model =
    if model.received then
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
