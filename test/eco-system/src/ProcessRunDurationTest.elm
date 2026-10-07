module ProcessRunDurationTest exposing (main)

{-| `runDuration` (plans/eco-system-library.md Phase 5 step 5.4, E.4):
`sleep 10` is killed with SIGTERM well within a second and the run fails with
ProgramError -1. A run that finishes before its (two minute) limit cancels the
timer (TimerService::cancel), so the program then exits promptly instead of
waiting for it: if it did not, the harness would time the test out. The same
holds for the default shell, which may leave `sleep` running behind a killed
`sh`; a killed run does not wait for the pipes to close.
-}

-- CHECK: killed: ProgramError -1 stdout=before| stderr= fast: True
-- CHECK: killed-shell: ProgramError -1 stdout= stderr= fast: True
-- CHECK: finished: ok stdout=done| stderr= fast: True
-- EXIT: 0

import ProcessTestHelp exposing (describeRun, noShell, simpleRun)
import System.Process as P
import Task exposing (Task)
import Time


timed : Int -> Task Never String -> Task Never String
timed limitMs task =
    Time.now
        |> Task.andThen
            (\start ->
                task
                    |> Task.andThen
                        (\s ->
                            Time.now
                                |> Task.map
                                    (\end ->
                                        let
                                            elapsed =
                                                Time.posixToMillis end - Time.posixToMillis start
                                        in
                                        s
                                            ++ " fast: "
                                            ++ (if elapsed < limitMs then
                                                    "True"

                                                else
                                                    "False (" ++ String.fromInt elapsed ++ " ms)"
                                               )
                                    )
                        )
            )


main =
    simpleRun
        [ ( "killed"
          , timed 1000
                (describeRun
                    (P.run "sh" [ "-c", "echo before; exec sleep 10" ] { noShell | runDuration = P.Milliseconds 200 })
                )
          )
        , ( "killed-shell"
          , timed 1000
                (describeRun
                    (P.run "sleep" [ "10" ] { noShell | shell = P.DefaultShell, runDuration = P.Milliseconds 200 })
                )
          )
        , ( "finished"
          , timed 5000
                (describeRun
                    (P.run "echo" [ "done" ] { noShell | runDuration = P.Milliseconds 120000 })
                )
          )
        ]
