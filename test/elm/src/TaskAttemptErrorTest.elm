module TaskAttemptErrorTest exposing (main)

{-| `Task.attempt` must deliver BOTH outcomes to `update`: the value on
success and the error on failure.

`attempt` routes through the same `spawnCmd` → `Platform.sendToApp` path as
`perform`, but wraps the task first (elm/core `Task.elm`):

    attempt resultToMessage task =
        command (Perform (
            task
                |> andThen (succeed << resultToMessage << Ok)
                |> onError (succeed << resultToMessage << Err)))

so it additionally pins `Scheduler.onError`'s two edges end to end — the
success path where the handler never runs, and the failure path where it
produces the task. Those are the two edges the LSS_022 `Scheduler.onError`
licence asserts, which is the other reason this fixture exists.

-}

-- CHECK: ok: 42
-- CHECK: err: "boom"

import Platform
import Task


type Msg
    = Got (Result String Int)


init : () -> ( Int, Cmd Msg )
init _ =
    ( 0
    , Cmd.batch
        [ Task.attempt Got (Task.succeed 42)
        , Task.attempt Got (Task.fail "boom")
        ]
    )


update : Msg -> Int -> ( Int, Cmd Msg )
update msg model =
    case msg of
        Got (Ok v) ->
            let
                _ =
                    Debug.log "ok" v
            in
            ( model + 1, Cmd.none )

        Got (Err e) ->
            let
                _ =
                    Debug.log "err" e
            in
            ( model + 1, Cmd.none )


main : Program () Int Msg
main =
    Platform.worker
        { init = init
        , update = update
        , subscriptions = \_ -> Sub.none
        }
