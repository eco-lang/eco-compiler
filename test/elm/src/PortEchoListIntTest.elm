port module PortEchoListIntTest exposing (main)

{-| A `List Int` sent out through a port comes back unchanged through an incoming
port, for each of three sample values.

The program assumes a host that passes every value sent out on the `echoOut`
port straight back in on the `echoIn` port; without one, nothing after `init`
is logged. It sends the values in `values` one at a time, sending the next only
after the previous one has come back, logs each value received, logs
`"done"` after the last one, and then drops its subscription.

The values are an empty list, a three-element list and the twenty-element
list `List.range 1 20`.

-}

-- CHECK: PortEchoListIntTest got: []
-- CHECK: PortEchoListIntTest got: [1,2,3]
-- CHECK: PortEchoListIntTest got: [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20]
-- CHECK: PortEchoListIntTest: "done"

import Platform


port echoOut : List Int -> Cmd msg


port echoIn : (List Int -> msg) -> Sub msg


values : List (List Int)
values =
    [ []
    , [ 1, 2, 3 ]
    , List.range 1 20
    ]


type Msg
    = Got (List Int)


type alias Model =
    { remaining : List (List Int), done : Bool }


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
            Debug.log "PortEchoListIntTest got" (v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoListIntTest" "done"
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
