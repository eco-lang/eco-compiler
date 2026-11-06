port module PortEchoStringTest exposing (main)

{-| A `String` sent out through a port comes back unchanged through an incoming
port, for each of six sample values.

The program assumes a host that passes every value sent out on the `echoOut`
port straight back in on the `echoIn` port; without one, nothing after `init`
is logged. It sends the values in `values` one at a time, sending the next only
after the previous one has come back, logs each value received as its list of
character codes, logs `"done"` after the last one, and then drops its subscription.

The values are the empty string, plain ASCII, a string with a double quote and
a backslash, a string with a newline and a tab, a string with a Latin-1
character and a character outside the Basic Multilingual Plane (U+1F600,
logged as the single code point 128512), and a string containing a NUL
character.

-}

-- CHECK: PortEchoStringTest got: []
-- CHECK: PortEchoStringTest got: [104,101,108,108,111]
-- CHECK: PortEchoStringTest got: [113,117,111,116,101,32,34,32,98,97,99,107,92,115,108,97,115,104]
-- CHECK: PortEchoStringTest got: [108,105,110,101,10,98,114,101,97,107,9,116,97,98]
-- CHECK: PortEchoStringTest got: [99,97,102,233,32,128512]
-- CHECK: PortEchoStringTest got: [110,117,108,0,105,110,115,105,100,101]
-- CHECK: PortEchoStringTest: "done"

import Platform


port echoOut : String -> Cmd msg


port echoIn : (String -> msg) -> Sub msg


values : List (String)
values =
    [ ""
    , "hello"
    , "quote \" back\\slash"
    , "line\nbreak\ttab"
    , "caf\u{00E9} \u{1F600}"
    , "nul\u{0000}inside"
    ]


type Msg
    = Got (String)


type alias Model =
    { remaining : List (String), done : Bool }


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
            Debug.log "PortEchoStringTest got" (List.map Char.toCode (String.toList v))
    in
    case model.remaining of
        next :: rest ->
            ( { model | remaining = rest }, echoOut next )

        [] ->
            let
                _ =
                    Debug.log "PortEchoStringTest" "done"
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
