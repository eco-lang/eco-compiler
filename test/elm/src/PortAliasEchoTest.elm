port module PortAliasEchoTest exposing (main)

{-| An outgoing port whose type is written through a type alias,
`port echoOut : Out msg` with `type alias Out msg = Payload -> Cmd msg`, sends
its record payload, and the record comes back unchanged through an incoming
port.

The program assumes a host that passes every value sent out on the `echoOut`
port straight back in on the `echoIn` port; without one, nothing after `init`
is logged. It sends `{ n = 42, s = "hi" }` once, logs the record received and
then `"ok"`, and drops its subscription.

-}

-- CHECK: PortAliasEchoTest got: { n = 42, s = "hi" }
-- CHECK: PortAliasEchoTest done: "ok"

import Platform


type alias Payload =
    { n : Int, s : String }


type alias Out msg =
    Payload -> Cmd msg


port echoOut : Out msg


port echoIn : (Payload -> msg) -> Sub msg


type Msg
    = Got Payload


type alias Model =
    { received : Bool }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { received = False }, echoOut { n = 42, s = "hi" } )


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Got payload ->
            let
                _ =
                    Debug.log "PortAliasEchoTest got" payload

                _ =
                    Debug.log "PortAliasEchoTest done" "ok"
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
