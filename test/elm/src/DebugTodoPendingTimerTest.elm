module DebugTodoPendingTimerTest exposing (main)

{-| CRASH-01 (plans/kernel-lib-bug-fixes.md), POSIX regression pin: `Debug.todo` prints its
message and exits with status 1 while a long timer is still pending (the timer service thread is
alive). `Elm_Kernel_Debug_todo` uses the same bare `exit(1)` as `Eco.Crash.crash` and
`Eco.Process.exit`, which the CRASH-01 fix moves to one `eco_terminate_process` helper.
CRASH-01 itself is a Windows-only hang (`::exit` with live service threads running DLL detach);
no test reaches it here. `Eco.Crash.crash` cannot be pinned in the JIT E2E harness
(`Eco_Kernel_Crash_crash` is not linked into it), so this pins the `Debug.todo` twin; it passes
today.

-}

-- CHECK: before todo
-- CHECK: Debug.todo: boom
-- CHECK-NOT: after todo
-- EXIT: 1

import Process
import Task


type Msg
    = Boom
    | Late


main : Program () () Msg
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , Cmd.batch
                    [ Task.perform (\_ -> Boom) (Process.sleep 10)
                    , Task.perform (\_ -> Late) (Process.sleep 60000)
                    ]
                )
        , update =
            \msg model ->
                case msg of
                    Boom ->
                        let
                            _ =
                                Debug.log "before todo" ()
                        in
                        Debug.todo "boom"

                    Late ->
                        let
                            _ =
                                Debug.log "after todo" ()
                        in
                        ( model, Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
