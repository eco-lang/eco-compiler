module ArrayFilterRebuild exposing (main)

-- CHECK: ArrayFilterRebuild: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


cycle : Array Int -> Bool
cycle original =
    let
        odds =
            Array.filter (\x -> modBy 2 x == 1) original

        evens =
            Array.filter (\x -> modBy 2 x == 0) original

        rebuilt =
            Array.append odds evens
                |> Array.toList
                |> List.sort
                |> Array.fromList
    in
    rebuilt == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            Array.initialize flags.maxSize (\i -> i + 1)
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ArrayFilterRebuild"
        , run = run
        }
