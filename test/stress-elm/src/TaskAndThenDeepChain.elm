module TaskAndThenDeepChain exposing (main)

{-| Build an `m`-deep Task.andThen chain counting up from 0, with a
Process.sleep 0 yield every 32 steps so the scheduler actually
re-enters the fiber. Checks the final accumulated value.

Stresses construction of TASK_AND_THEN heap nodes, the stack-frame list
built up in stepProcess during unwinding, and the interaction between
synchronous andThen folding and periodic BINDING yields.
-}

-- CHECK: TaskAndThenDeepChain: True

import Process
import StressHarness exposing (StressFlags)
import Task exposing (Task)


yieldEvery : Int
yieldEvery =
    32


step : Int -> Int -> Task Never Int
step i x =
    if modBy yieldEvery i == 0 then
        Process.sleep 0 |> Task.map (\_ -> x + 1)

    else
        Task.succeed (x + 1)


buildChain : Int -> Task Never Int
buildChain depth =
    let
        go i task =
            if i > depth then
                task

            else
                go (i + 1) (task |> Task.andThen (step i))
    in
    go 1 (Task.succeed 0)


cycle : Int -> Task Never Bool
cycle depth =
    buildChain depth
        |> Task.map (\v -> v == depth)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        depth =
            flags.maxSize
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> cycle depth)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "TaskAndThenDeepChain"
        , run = run
        }
