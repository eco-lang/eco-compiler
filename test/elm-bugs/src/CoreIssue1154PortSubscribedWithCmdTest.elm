port module CoreIssue1154PortSubscribedWithCmdTest exposing (main)

{-| A port subscription added by the same `update` that sends a command to an outgoing port misses
the outgoing port's synchronous reply, depending on the order of the ports in the generated code.

<https://github.com/elm/core/issues/1154>

`update` returns `echoOut "hello"` and a model whose `subscriptions` are `echoIn Got`. The host
(the test runner) answers every `echoOut` value synchronously through `echoIn`.
In Elm 0.19.1 the reply is dropped and `Got` never arrives, because the command is dispatched before the new subscription is in place
(this depends on `echoOut` also being used in `init`).
Subscriptions returned together with a command must be active when the command runs.

-}

-- CHECK: got: "hello"

import Process
import Task


port echoOut : String -> Cmd msg


port echoIn : (String -> msg) -> Sub msg


type Msg
    = Start
    | Got String


init : () -> ( Bool, Cmd Msg )
init _ =
    ( False
    , Cmd.batch
        [ echoOut "init"
        , Task.perform (always Start) (Process.sleep 10)
        ]
    )


update : Msg -> Bool -> ( Bool, Cmd Msg )
update msg listening =
    case msg of
        Start ->
            ( True, echoOut "hello" )

        Got s ->
            let
                _ =
                    Debug.log "got" s
            in
            ( listening, Cmd.none )


subscriptions : Bool -> Sub Msg
subscriptions listening =
    if listening then
        echoIn Got

    else
        Sub.none


main : Program () Bool Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = subscriptions
        }
