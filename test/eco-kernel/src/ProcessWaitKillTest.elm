module ProcessWaitKillTest exposing (main)

{-| PROC-08 (plans/kernel-lib-bug-fixes.md, group 07): killing a task blocked in
`Eco.Process.wait` must stop it from keeping the program alive (LIVE_001). Natively `waitBody`
(eco-kernel-cpp/src/eco-kernel/Process.cpp) returned `()` as the kill handle, so `Process.kill` on
the waiter did nothing: its hold lasted until the child exited. Fixed: the kill handle releases
the hold (and the drain then skips its release).

The probe: the child sleeps 4 s and then prints `late-child-output`. The waiter is killed 100 ms
in, after which nothing else is pending, so the program should end at once; the harness reads the
output as soon as the program exits, long before the orphaned child prints. Before the fix the
program lived until the child exited, so the late line was in the output. Killing the waiter does not kill
the child (Elm/Node semantics; the JS twin does not either). POSIX only (`sh`).
-}

-- LINUX-ONLY: uses sh
-- CHECK: killed
-- CHECK-NOT: late-child-output
-- EXIT: 0

import Eco.Process as P
import Platform
import Process
import Task


type Msg
    = Killed


main : Program () () Msg
main =
    Platform.worker
        { init =
            \_ ->
                ( ()
                , P.spawn "sh" [ "-c", "sleep 4; echo late-child-output" ]
                    |> Task.andThen (\h -> Process.spawn (P.wait h))
                    |> Task.andThen (\waiter -> Process.sleep 100 |> Task.andThen (\_ -> Process.kill waiter))
                    |> Task.onError (\_ -> Task.succeed ())
                    |> Task.perform (\_ -> Killed)
                )
        , update =
            \Killed _ ->
                let
                    _ =
                        Debug.log "killed" ()
                in
                ( (), Cmd.none )
        , subscriptions = \_ -> Sub.none
        }
