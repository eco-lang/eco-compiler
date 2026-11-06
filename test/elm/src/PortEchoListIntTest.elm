port module PortEchoListIntTest exposing (main)

{-| A `List Int` out and back in over ports. The harness echo (test/ElmE2ETestBase.hpp
`installPortEchoBounce` under the JIT, test/aot_port_host.cpp under AOT, and
test/scripts/run-elm-e2e.js for stock Elm on Node) feeds every `echoOut` payload back
into `echoIn`. Each value is sent once the previous one
has come back, so the order is the same on every backend, and the subscription is dropped
after the last so the program ends. Expected output recorded from Elm on node.

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
