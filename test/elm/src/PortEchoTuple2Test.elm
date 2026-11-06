port module PortEchoTuple2Test exposing (main)

{-| A `( Int, String )` sent out through an outgoing port comes back unchanged through an incoming port.

The test host must feed every payload of the outgoing port `echoOut` back into the incoming
port `echoIn`. The program sends `( 1, "one" )` and `( -2, "" )`, one at a time: each value goes out only after
the previous one has come back and been logged, so the log order is fixed. After the last
value it logs `done` and `subscriptions` returns `Sub.none` so the program can finish.

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
