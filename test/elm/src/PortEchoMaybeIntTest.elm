port module PortEchoMaybeIntTest exposing (main)

{-| A `Maybe Int` sent out through a port comes back unchanged through an incoming
port, for each of three sample values.

The program assumes a host that passes every value sent out on the `echoOut`
port straight back in on the `echoIn` port; without one, nothing after `init`
is logged. It sends the values in `values` one at a time, sending the next only
after the previous one has come back, logs each value received, logs
`"done"` after the last one, and then drops its subscription.

The values are `Just 3`, `Nothing` and `Just -7`.

-}

-- CHECK: PortEchoMaybeIntTest got: Just 3
-- CHECK: PortEchoMaybeIntTest got: Nothing
-- CHECK: PortEchoMaybeIntTest got: Just -7
-- CHECK: PortEchoMaybeIntTest: "done"

import Platform


port echoOut : Maybe Int -> Cmd msg


port echoIn : (Maybe Int -> msg) -> Sub msg


values : List (Maybe Int)
values =
    [ Just 3
    , Nothing
    , Just (-7)
    ]


type Msg
    = Got (Maybe Int)


type alias Model =
    { remaining : List (Maybe Int), done : Bool }


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
            Debug.log "PortEchoMaybeIntTest got" (v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoMaybeIntTest" "done"
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
