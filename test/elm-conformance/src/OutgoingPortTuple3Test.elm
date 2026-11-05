port module OutgoingPortTuple3Test exposing (main)

{-| An outgoing port whose payload is a 3-tuple. Its encoder runs when the command is processed,
whether or not anything subscribes to the port, so the program must get past that point and log
"after". The erased (JS) port encoder read the third element as `$.cs[0]`, the layout of tuples of
more than three elements, which an Elm 3-tuple (`{ a, b, c }`) does not have: the encoder threw a
TypeError and the program died before "after". The native twin of this bug was a compiler crash
(test/elm/src/OutgoingPortTuple3Test.elm). Expected output recorded from Elm on node.
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
