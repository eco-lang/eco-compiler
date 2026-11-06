port module PortEchoFloatTest exposing (main)

{-| A `Float` sent out through a port comes back unchanged through an incoming
port, for each of seven sample values.

The program assumes a host that passes every value sent out on the `echoOut`
port straight back in on the `echoIn` port; without one, nothing after `init`
is logged. It sends the values in `values` one at a time, sending the next only
after the previous one has come back, logs each value received, logs
`"done"` after the last one, and then drops its subscription.

The values include zero, negative numbers, a value with no exact binary
representation (0.1), and large and small magnitudes written in exponent
notation (`3.0e10`, `-1.0e-7`).

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
