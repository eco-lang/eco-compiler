port module CoreIssue1141UnusedPortCallBreaksSubscriptionTest exposing (main)

{-| An unused port call (`_ = echoOut "unused"` in `init`) breaks a port subscription elsewhere.

<https://github.com/elm/core/issues/1141>

`update` returns `echoOut "hello"` and a model whose `subscriptions` are `echoIn Got`. The host
(the test runner) answers every `echoOut` value synchronously through `echoIn`.
In Elm 0.19.1 the reply is dropped and `Got` never arrives, because the command is dispatched before the new subscription is in place
(removing the unused `echoOut` call in `init` avoids this).
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
    let
        -- unused, but its presence is what triggers the Elm 0.19.1 bug
        _ =
            echoOut "unused"
    in
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
