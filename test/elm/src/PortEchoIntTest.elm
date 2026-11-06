port module PortEchoIntTest exposing (main)

{-| An `Int` sent out through a port comes back unchanged through an incoming
port, for each of seven sample values.

The program assumes a host that passes every value sent out on the `echoOut`
port straight back in on the `echoIn` port; without one, nothing after `init`
is logged. It sends the values in `values` one at a time, sending the next only
after the previous one has come back, logs each value received, logs
`"done"` after the last one, and then drops its subscription.

The values include 0, -1, the 32-bit signed limits (2147483647 and
-2147483648), and the largest and smallest integers a JavaScript number holds
exactly (9007199254740991 and -9007199254740991).

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
