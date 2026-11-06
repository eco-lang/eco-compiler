module CoreIssue955KillProcessTwiceTest exposing (main)

{-| Killing a process that has already finished, a second time, throws a JavaScript error.

<https://github.com/elm/core/issues/955>

Elm 0.19.1 crashes with `TypeError: Cannot read properties of null (reading '$')`. Killing a
dead process should be a no-op, and the task should complete.

-}

-- CHECK: killed twice: ()

import Process
import Task exposing (Task)


killProcessTwice : Task Never ()
killProcessTwice =
    Process.spawn (Task.succeed ())
        |> Task.andThen
            (\pid ->
                Process.kill pid
                    |> Task.andThen (\_ -> Process.kill pid)
            )


main : Program () () ()
main =
    Platform.worker
        { init = \_ -> ( (), Task.perform identity killProcessTwice )
        , update = \msg model -> ( Debug.log "killed twice" msg |> always model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
