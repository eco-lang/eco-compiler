port module PortEchoBoolTest exposing (main)

{-| A `Bool` sent out through a port comes back unchanged through an incoming
port, for each of two sample values.

The program assumes a host that passes every value sent out on the `echoOut`
port straight back in on the `echoIn` port; without one, nothing after `init`
is logged. It sends the values in `values` one at a time, sending the next only
after the previous one has come back, logs each value received, logs
`"done"` after the last one, and then drops its subscription.

The values are `True` and `False`.

-}

-- CHECK: PortEchoBoolTest got: True
-- CHECK: PortEchoBoolTest got: False
-- CHECK: PortEchoBoolTest: "done"

import Platform


port echoOut : Bool -> Cmd msg


port echoIn : (Bool -> msg) -> Sub msg


values : List (Bool)
values =
    [ True
    , False
    ]


type Msg
    = Got (Bool)


type alias Model =
    { remaining : List (Bool), done : Bool }


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
            Debug.log "PortEchoBoolTest got" (v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoBoolTest" "done"
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
