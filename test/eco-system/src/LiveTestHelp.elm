module LiveTestHelp exposing (log, node)

{-| Helpers for the liveness tests (plans/program-liveness-rule.md §11.1; not a
test: no `main`): logging a line, and starting a Detached Node process as an
external peer, which does not keep the program running.
-}

import ChildProcess as Process
import Stream
import System
import Task


{-| Writes `line` to stdout and then sends `msg`.
-}
log : System.Environment -> msg -> String -> Cmd msg
log env msg line =
    Task.perform (\_ -> msg) (Stream.logLine line env.stdout)


{-| Starts `node -e script` as a Detached child; both of its msgs are `msg`.
-}
node : msg -> String -> Cmd msg
node msg script =
    Process.spawn "node"
        [ "-e", script ]
        (Process.defaultSpawnOptions (Process.Detached (\_ -> msg)) (\_ -> msg)
            |> (\o -> { o | shell = Process.NoShell })
        )
