port module PortEchoUnitTest exposing (main)

{-| A `()` sent out through an outgoing port comes back unchanged through an incoming port.

The test host must feed every payload of the outgoing port `echoOut` back into the incoming
port `echoIn`. The program sends `()` twice, one at a time: each value goes out only after
the previous one has come back and been logged, so the log order is fixed. After the last
value it logs `done` and `subscriptions` returns `Sub.none` so the program can finish.

-}

-- CHECK: PortEchoUnitTest got: ()
-- CHECK: PortEchoUnitTest got: ()
-- CHECK: PortEchoUnitTest: "done"

import Platform


port echoOut : () -> Cmd msg


port echoIn : (() -> msg) -> Sub msg


values : List (())
values =
    [ ()
    , ()
    ]


type Msg
    = Got (())


type alias Model =
    { remaining : List (()), done : Bool }


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
            Debug.log "PortEchoUnitTest got" (v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoUnitTest" "done"
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
