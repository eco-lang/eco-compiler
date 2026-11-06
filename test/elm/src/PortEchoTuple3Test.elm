port module PortEchoTuple3Test exposing (main)

{-| A `( Int, Float, Bool )` sent out through an outgoing port comes back unchanged through an incoming port.

The test host must feed every payload of the outgoing port `echoOut` back into the incoming
port `echoIn`. The program sends `( 1, 2.5, True )` and `( 0, -0.5, False )`, one at a time: each value goes out only after
the previous one has come back and been logged, so the log order is fixed. After the last
value it logs `done` and `subscriptions` returns `Sub.none` so the program can finish.

-}

-- CHECK: PortEchoTuple3Test got: (1,2.5,True)
-- CHECK: PortEchoTuple3Test got: (0,-0.5,False)
-- CHECK: PortEchoTuple3Test: "done"

import Platform


port echoOut : ( Int, Float, Bool ) -> Cmd msg


port echoIn : (( Int, Float, Bool ) -> msg) -> Sub msg


values : List (( Int, Float, Bool ))
values =
    [ ( 1, 2.5, True )
    , ( 0, -0.5, False )
    ]


type Msg
    = Got (( Int, Float, Bool ))


type alias Model =
    { remaining : List (( Int, Float, Bool )), done : Bool }


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
            Debug.log "PortEchoTuple3Test got" (v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoTuple3Test" "done"
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
