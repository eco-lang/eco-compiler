port module PortEchoJsonValueTest exposing (main)

{-| A `Encode.Value` out and back in over ports. The harness echo (test/ElmE2ETestBase.hpp
`installPortEchoBounce` under the JIT, test/aot_port_host.cpp under AOT, and
test/scripts/run-elm-e2e.js for stock Elm on Node) feeds every `echoOut` payload back
into `echoIn`. Each value is sent once the previous one
has come back, so the order is the same on every backend, and the subscription is dropped
after the last so the program ends. Expected output recorded from Elm on node.

-}

-- CHECK: PortEchoJsonValueTest got: "{\"a\":[1,true,null],\"b\":\"x\"}"
-- CHECK: PortEchoJsonValueTest got: "\"plain\""
-- CHECK: PortEchoJsonValueTest got: "2.5"
-- CHECK: PortEchoJsonValueTest got: "null"
-- CHECK: PortEchoJsonValueTest: "done"

import Json.Encode as Encode
import Platform


port echoOut : Encode.Value -> Cmd msg


port echoIn : (Encode.Value -> msg) -> Sub msg


values : List (Encode.Value)
values =
    [ Encode.object [ ( "a", Encode.list identity [ Encode.int 1, Encode.bool True, Encode.null ] ), ( "b", Encode.string "x" ) ]
    , Encode.string "plain"
    , Encode.float 2.5
    , Encode.null
    ]


type Msg
    = Got (Encode.Value)


type alias Model =
    { remaining : List (Encode.Value), done : Bool }


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
            Debug.log "PortEchoJsonValueTest got" (Encode.encode 0 v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoJsonValueTest" "done"
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
