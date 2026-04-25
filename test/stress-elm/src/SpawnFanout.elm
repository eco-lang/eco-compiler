module SpawnFanout exposing (main)

{-| Spawn many fibers in a tight loop, each of which yields via
Process.sleep 0 and then performs a small fold. The parent waits
long enough for the run queue to drain, then reports True.

Stresses rawSpawn throughput, nextProcessId_, enqueue under an
active drain, and GC of many short-lived Process heap objects.
-}

-- CHECK: SpawnFanout: True

import Process
import StressHarness exposing (StressFlags)
import Task


sumTo : Int -> Int -> Int
sumTo k acc =
    if k <= 0 then
        acc

    else
        sumTo (k - 1) (acc + k)


worker : Int -> Task.Task Never ()
worker i =
    Process.sleep 0
        |> Task.andThen
            (\_ ->
                let
                    _ =
                        sumTo (modBy 64 i + 1) 0
                in
                Task.succeed ()
            )


spawnAll : Int -> Task.Task Never ()
spawnAll fiberCount =
    let
        go k =
            if k > fiberCount then
                Task.succeed ()

            else
                Process.spawn (worker k)
                    |> Task.andThen (\_ -> go (k + 1))
    in
    go 1


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount =
            flags.numLoops // 100

        fiberCount =
            flags.maxSize * loopCount
    in
    spawnAll fiberCount
        |> Task.andThen (\_ -> Process.sleep 500)
        |> Task.map (\_ -> True)


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "SpawnFanout"
        , run = run
        }
