module TaskSequenceMassive exposing (main)

{-| Task.sequence applied to an `m`-element list of tasks alternating
between synchronous (Task.succeed i) and asynchronous
(Process.sleep 0 |> map (\_ -> i)) leaves. Sum the resulting list and
check the total.

Stresses Task.sequence's cons-fold allocation path and the run queue
under mixed sync / async leaves.
-}

-- CHECK: TaskSequenceMassive: True

import Process
import StressHarness exposing (StressFlags)
import Task exposing (Task)


leaf : Int -> Task Never Int
leaf i =
    if modBy 2 i == 0 then
        Task.succeed i

    else
        Process.sleep 0 |> Task.map (\_ -> i)


buildTasks : Int -> List (Task Never Int)
buildTasks leafCount =
    let
        go i acc =
            if i < 0 then
                acc

            else
                go (i - 1) (leaf i :: acc)
    in
    go (leafCount - 1) []


cycle : Int -> Task Never Bool
cycle leafCount =
    let
        expected =
            leafCount * (leafCount - 1) // 2
    in
    Task.sequence (buildTasks leafCount)
        |> Task.map (List.foldl (+) 0)
        |> Task.map (\v -> v == expected)


run : StressFlags -> Task.Task Never Bool
run flags =
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> cycle flags.maxSize)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "TaskSequenceMassive"
        , run = run
        }
