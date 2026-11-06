port module PortEchoArrayStringTest exposing (main)

{-| An `Array String` sent out through a port comes back unchanged through an incoming
port, for each of two sample values.

The program assumes a host that passes every value sent out on the `echoOut`
port straight back in on the `echoIn` port; without one, nothing after `init`
is logged. It sends the values in `values` one at a time, sending the next only
after the previous one has come back, logs each value received, logs
`"done"` after the last one, and then drops its subscription.

The values are an empty array and a three-element array.

-}

-- CHECK: PortEchoArrayStringTest got: Array.fromList []
-- CHECK: PortEchoArrayStringTest got: Array.fromList ["a","b","c"]
-- CHECK: PortEchoArrayStringTest: "done"

import Array exposing (Array)
import Platform


port echoOut : Array String -> Cmd msg


port echoIn : (Array String -> msg) -> Sub msg


values : List (Array String)
values =
    [ Array.empty
    , Array.fromList [ "a", "b", "c" ]
    ]


type Msg
    = Got (Array String)


type alias Model =
    { remaining : List (Array String), done : Bool }


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
            Debug.log "PortEchoArrayStringTest got" (v)
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoArrayStringTest" "done"
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
