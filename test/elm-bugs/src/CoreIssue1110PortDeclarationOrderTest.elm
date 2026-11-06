port module CoreIssue1110PortDeclarationOrderTest exposing (main)

{-| A subscription returned together with a port command is active in time to receive that command's synchronous reply.

<https://github.com/elm/core/issues/1110>

On `Start`, `update` returns `echoOut "hello"` and a model for which `zsubscriptions` returns
`echoIn Got`. The test's host answers each `echoOut` value synchronously on `echoIn`, so `Got
"hello"` should arrive. In Elm 0.19.1 the outcome depends on declaration order: with the
subscriptions function named so that it sorts after `update`, the command is dispatched before the
new subscription is in place and the reply is dropped.

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
