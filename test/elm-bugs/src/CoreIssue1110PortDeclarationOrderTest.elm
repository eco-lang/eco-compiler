port module CoreIssue1110PortDeclarationOrderTest exposing (main)

{-| The order of port declarations in the generated JavaScript decides whether a subscription
returned together with a command sees that command's synchronous reply.

<https://github.com/elm/core/issues/1110>

`update` returns `echoOut "hello"` and a model whose `subscriptions` are `echoIn Got`. The host
(the test runner) answers every `echoOut` value synchronously through `echoIn`. Only because the
subscriptions function is named `zsubscriptions` (sorting after `update`), Elm 0.19.1 registers the effect manager of `echoOut` first and dispatches the command
before the new subscription is in place, so the reply is dropped and `Got` never arrives.
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
    ( False, Task.perform (always Start) (Process.sleep 10) )


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


zsubscriptions : Bool -> Sub Msg
zsubscriptions listening =
    if listening then
        echoIn Got

    else
        Sub.none


main : Program () Bool Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = zsubscriptions
        }
