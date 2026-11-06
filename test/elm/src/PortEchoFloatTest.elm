port module PortEchoFloatTest exposing (main)

{-| A `Float` out and back in over ports. The harness echo (test/ElmE2ETestBase.hpp
`installPortEchoBounce` under the JIT, test/aot_port_host.cpp under AOT, and
test/scripts/run-elm-e2e.js for stock Elm on Node) feeds every `echoOut` payload back
into `echoIn`. Each value is sent once the previous one
has come back, so the order is the same on every backend, and the subscription is dropped
after the last so the program ends. Expected output recorded from Elm on node.

-}

-- CHECK: PortEchoFloatTest got: 0
-- CHECK: PortEchoFloatTest got: 1.5
-- CHECK: PortEchoFloatTest got: -0.25
-- CHECK: PortEchoFloatTest got: 0.1
-- CHECK: PortEchoFloatTest got: 30000000000
-- CHECK: PortEchoFloatTest got: -1e-7
-- CHECK: PortEchoFloatTest got: 123456.789
-- CHECK: PortEchoFloatTest: "done"

import Platform


port echoOut : Float -> Cmd msg


port echoIn : (Float -> msg) -> Sub msg


values : List (Float)
values =
    [ 0
    , 1.5
    , -0.25
    , 0.1
    , 3.0e10
    , -1.0e-7
    , 123456.789
    ]


type Msg
    = Got (Float)


type alias Model =
    { remaining : List (Float), done : Bool }


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
            Debug.log "PortEchoFloatTest got" (v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoFloatTest" "done"
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
