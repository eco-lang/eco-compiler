port module PortEchoNestedTest exposing (main)

{-| A `List (Maybe ( Int, List String ))` sent out through a port comes back unchanged through an incoming
port, for each of two sample values.

The program assumes a host that passes every value sent out on the `echoOut`
port straight back in on the `echoIn` port; without one, nothing after `init`
is logged. It sends the values in `values` one at a time, sending the next only
after the previous one has come back, logs each value received, logs
`"done"` after the last one, and then drops its subscription.

The values are a list mixing `Just` and `Nothing`, including a pair with an
empty inner list, and an empty list.

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
