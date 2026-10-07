module TerminalOnResizeTest exposing (main)

{-| `System.Terminal.onResize` (plans/eco-system-library.md Phase 5 step 5.3):
the subscription installs a SIGWINCH listener through SignalService, holds
no pendingAsync (resize subscriptions do not keep the program alive, §3.4),
and delivers nothing when no stdio fd is a terminal (as Node's stdout
'resize'). A child sends SIGWINCH to this program; the program carries on and
exits 0 once its work is done.
-}

-- CHECK: winch sent: ok
-- CHECK-NOT: resized
-- EXIT: 0

import ProcessTestHelp exposing (noShell)
import Stream.Log
import System
import System.Process as P
import System.Terminal as Terminal
import Task


type Msg
    = Start
    | Sent String
    | Resized Terminal.Size
    | Logged


main : System.Program System.Environment Msg
main =
    System.defineProgram
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
                        ( env, Task.perform (\_ -> Logged) (Stream.Log.line env.stdout ("winch sent: " ++ r)) )

                    Resized size ->
                        ( env
                        , Task.perform (\_ -> Logged)
                            (Stream.Log.line env.stdout
                                ("resized " ++ String.fromInt size.columns ++ "x" ++ String.fromInt size.rows)
                            )
                        )

                    Logged ->
                        ( env, Cmd.none )
        , subscriptions = \_ -> Terminal.onResize Resized
        }
