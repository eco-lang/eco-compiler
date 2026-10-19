module TerminalOnResizeTest exposing (main)

{-| `Terminal.onResize` (plans/eco-system-library.md Phase 5 step 5.3):
the subscription installs a SIGWINCH listener through SignalService, holds
no pendingAsync (resize subscriptions do not keep the program alive, §3.4),
and delivers nothing when no stdio fd is a terminal (as Node's stdout
'resize'). A child sends SIGWINCH to this program; the program carries on and
exits 0 once its work is done.
-}

-- CHECK: winch sent: ok
-- CHECK-NOT: resized
-- EXIT: 0

import ChildProcess as P
import ProcessTestHelp exposing (noShell)
import Stream
import System
import Task
import Terminal


type Msg
    = Start
    | Sent String
    | Resized Terminal.Size
    | Logged


main : Platform.Program System.Environment System.Environment Msg
main =
    Platform.worker
        { init = \env -> ( env, Task.perform (\_ -> Start) (Task.succeed ()) )
        , update =
            \msg env ->
                case msg of
                    Start ->
                        ( env
                        , P.run "sh" [ "-c", "kill -WINCH $PPID" ] noShell
                            |> Task.map (\_ -> "ok")
                            |> Task.onError (\_ -> Task.succeed "failed")
                            |> Task.perform Sent
                        )

                    Sent r ->
                        ( env, Task.perform (\_ -> Logged) (Stream.logLine ("winch sent: " ++ r) env.stdout) )

                    Resized size ->
                        ( env
                        , Task.perform (\_ -> Logged)
                            (Stream.logLine ("resized " ++ String.fromInt size.columns ++ "x" ++ String.fromInt size.rows) env.stdout)
                        )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Terminal.onResize Resized
        }
