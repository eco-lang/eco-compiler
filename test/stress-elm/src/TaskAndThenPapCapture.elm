module TaskAndThenPapCapture exposing (main)

{-| A Task-based analogue of BytesRoundtripAndThenChain: a six-deep
andThen chain where every callback captures *all* previously bound
values before the next bind. Each iteration allocates a fresh pap
extension for each level.

Stresses eco_pap_extend closure growth across scheduler yields. Each
level yields via Process.sleep 0 so the scheduler must re-enter the
fiber with the growing capture chain live on its stack-frame list.
-}

-- CHECK: TaskAndThenPapCapture: True

import Process
import StressHarness exposing (StressFlags)
import Task exposing (Task)


{-| Six-deep andThen chain where each callback captures every value
decoded so far before producing the next.
-}
sixLevel : Int -> Task Never Int
sixLevel base =
    Process.sleep 0
        |> Task.andThen
            (\_ ->
                let
                    a =
                        base + 1
                in
                Process.sleep 0
                    |> Task.andThen
                        (\_ ->
                            let
                                b =
                                    a + 2
                            in
                            Process.sleep 0
                                |> Task.andThen
                                    (\_ ->
                                        let
                                            c =
                                                b + 3
                                        in
                                        Process.sleep 0
                                            |> Task.andThen
                                                (\_ ->
                                                    let
                                                        d =
                                                            c + 4
                                                    in
                                                    Process.sleep 0
                                                        |> Task.andThen
                                                            (\_ ->
                                                                let
                                                                    e =
                                                                        d + 5
                                                                in
                                                                Process.sleep 0
                                                                    |> Task.map
                                                                        (\_ -> a + b + c + d + e + 6)
                                                            )
                                                )
                                    )
                        )
            )


cycle : Task Never Bool
cycle =
    sixLevel 0 |> Task.map (\v -> v == 41)


run : StressFlags -> Task.Task Never Bool
run flags =
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> cycle)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "TaskAndThenPapCapture"
        , run = run
        }
