port module PortEchoTest exposing (main)

{-| End-to-end native ports test (plans/native-ports-and-embedding.md).

The test harness wires a generic echo: every payload sent through the
outgoing `echoOut` port is bounced back into the incoming `echoIn` port
(see runElmTestFromMlir in test/ElmE2ETestBase.hpp). This exercises the
full path on both directions: eager encode -> Fx_Leaf -> port effect
manager -> host callback -> eco_port_send -> queued drain -> Json decode
-> tagger -> sendToApp -> update.

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
