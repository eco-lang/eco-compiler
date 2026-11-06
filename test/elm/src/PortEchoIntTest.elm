port module PortEchoIntTest exposing (main)

{-| A `Int` out and back in over ports. The harness echo (test/ElmE2ETestBase.hpp
`installPortEchoBounce` under the JIT, test/aot_port_host.cpp under AOT, and
test/scripts/run-elm-e2e.js for stock Elm on Node) feeds every `echoOut` payload back
into `echoIn`. Each value is sent once the previous one
has come back, so the order is the same on every backend, and the subscription is dropped
after the last so the program ends. Expected output recorded from Elm on node.

-}

-- CHECK: PortEchoIntTest got: 0
-- CHECK: PortEchoIntTest got: -1
-- CHECK: PortEchoIntTest got: 42
-- CHECK: PortEchoIntTest got: 2147483647
-- CHECK: PortEchoIntTest got: -2147483648
-- CHECK: PortEchoIntTest got: 9007199254740991
-- CHECK: PortEchoIntTest got: -9007199254740991
-- CHECK: PortEchoIntTest: "done"

import Platform


port echoOut : Int -> Cmd msg


port echoIn : (Int -> msg) -> Sub msg


values : List (Int)
values =
    [ 0
    , -1
    , 42
    , 2147483647
    , -2147483648
    , 9007199254740991
    , -9007199254740991
    ]


type Msg
    = Got (Int)


type alias Model =
    { remaining : List (Int), done : Bool }


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
            Debug.log "PortEchoIntTest got" (v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoIntTest" "done"
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
