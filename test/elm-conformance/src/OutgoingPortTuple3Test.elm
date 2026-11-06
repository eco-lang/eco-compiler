port module OutgoingPortTuple3Test exposing (main)

{-| A program that sends a 3-tuple through an outgoing port keeps running afterwards.

The port's payload is `( String, Int, List String )`. Nothing subscribes to the port. The command
is batched with a 10 ms sleep, and the program must log "sent" before it and "after" when the
sleep ends.

-}

-- CHECK: OutgoingPortTuple3Test: "sent"
-- CHECK: OutgoingPortTuple3Test: "after"

import Platform
import Process
import Task


port out3 : ( String, Int, List String ) -> Cmd msg


type Msg
    = After


init : () -> ( (), Cmd Msg )
init _ =
    let
        _ =
            Debug.log "OutgoingPortTuple3Test" "sent"
    in
    ( ()
    , Cmd.batch
        [ out3 ( "name.elm", 3, [ "x", "y" ] )
        , Task.perform (\_ -> After) (Process.sleep 10)
        ]
    )


update : Msg -> () -> ( (), Cmd Msg )
update After model =
    let
        _ =
            Debug.log "OutgoingPortTuple3Test" "after"
    in
    ( model, Cmd.none )


main : Program () () Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
