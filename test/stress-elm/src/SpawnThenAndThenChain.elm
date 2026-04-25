module SpawnThenAndThenChain exposing (main)

{-| Spawn fibers, each running a Process.sleep 0 + andThen chain.
Combines fan-out breadth with chain depth.

Stresses the run queue under continuous re-enqueue and pap-extend
allocation while many fibers are simultaneously waiting on timers.
-}

-- CHECK: SpawnThenAndThenChain: True

import Process
import StressHarness exposing (StressFlags)
import Task


innerChain : Int -> Int -> Task.Task Never Int
innerChain i acc =
    if i <= 0 then
        Task.succeed acc

    else
        Process.sleep 0
            |> Task.andThen (\_ -> innerChain (i - 1) (acc + 1))


worker : Int -> Task.Task Never ()
worker chainDepth =
    innerChain chainDepth 0
        |> Task.map (\_ -> ())


spawnAll : Int -> Int -> Task.Task Never ()
spawnAll fiberCount chainDepth =
    let
        go k =
            if k > fiberCount then
                Task.succeed ()

            else
                Process.spawn (worker chainDepth)
                    |> Task.andThen (\_ -> go (k + 1))
    in
    go 1


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        fiberCount =
            flags.maxSize // 5

        chainDepth =
            flags.maxSize // 20
    in
    spawnAll fiberCount chainDepth
        |> Task.andThen (\_ -> Process.sleep 1000)
        |> Task.map (\_ -> True)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "SpawnThenAndThenChain"
        , run = run
        }
