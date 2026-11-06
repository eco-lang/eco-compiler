port module OutgoingPortTuple3Test exposing (main)

{-| Tests that a program with an outgoing port whose payload is a 3-tuple
`( String, String, List String )` compiles and runs.

`init` logs `"sent"` and returns a command sending one tuple through the port.
The test checks only the log line; nothing subscribes to the port, so what
is sent is not observed.

-}

-- CHECK: OutgoingPortTuple3Test: "sent"

import Platform


port out3 : ( String, String, List String ) -> Cmd msg


init : () -> ( (), Cmd msg )
init _ =
    let
        _ =
            Debug.log "OutgoingPortTuple3Test" "sent"
    in
    ( (), out3 ( "name.elm", "body", [ "x", "y" ] ) )


main : Program () () msg
main =
    Platform.worker
        { init = init
        , update = \_ model -> ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
