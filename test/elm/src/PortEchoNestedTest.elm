port module PortEchoNestedTest exposing (main)

{-| A `List (Maybe ( Int, List String ))` out and back in over ports. The harness echo (test/ElmE2ETestBase.hpp
`installPortEchoBounce` under the JIT, test/aot_port_host.cpp under AOT, and
test/scripts/run-elm-e2e.js for stock Elm on Node) feeds every `echoOut` payload back
into `echoIn`. Each value is sent once the previous one
has come back, so the order is the same on every backend, and the subscription is dropped
after the last so the program ends. Expected output recorded from Elm on node.

-}

-- CHECK: PortEchoNestedTest got: [Just (1,["x","y"]),Nothing,Just (2,[])]
-- CHECK: PortEchoNestedTest got: []
-- CHECK: PortEchoNestedTest: "done"

import Platform


port echoOut : List (Maybe ( Int, List String )) -> Cmd msg


port echoIn : (List (Maybe ( Int, List String )) -> msg) -> Sub msg


values : List (List (Maybe ( Int, List String )))
values =
    [ [ Just ( 1, [ "x", "y" ] ), Nothing, Just ( 2, [] ) ]
    , []
    ]


type Msg
    = Got (List (Maybe ( Int, List String )))


type alias Model =
    { remaining : List (List (Maybe ( Int, List String ))), done : Bool }


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
            Debug.log "PortEchoNestedTest got" (v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoNestedTest" "done"
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
