port module PortEchoTuple2Test exposing (main)

{-| A `( Int, String )` out and back in over ports. The harness echo (test/ElmE2ETestBase.hpp
`installPortEchoBounce` under the JIT, test/aot_port_host.cpp under AOT, and
test/scripts/run-elm-e2e.js for stock Elm on Node) feeds every `echoOut` payload back
into `echoIn`. Each value is sent once the previous one
has come back, so the order is the same on every backend, and the subscription is dropped
after the last so the program ends. Expected output recorded from Elm on node.

-}

-- CHECK: PortEchoTuple2Test got: (1,"one")
-- CHECK: PortEchoTuple2Test got: (-2,"")
-- CHECK: PortEchoTuple2Test: "done"

import Platform


port echoOut : ( Int, String ) -> Cmd msg


port echoIn : (( Int, String ) -> msg) -> Sub msg


values : List (( Int, String ))
values =
    [ ( 1, "one" )
    , ( -2, "" )
    ]


type Msg
    = Got (( Int, String ))


type alias Model =
    { remaining : List (( Int, String )), done : Bool }


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
            Debug.log "PortEchoTuple2Test got" (v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoTuple2Test" "done"
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
