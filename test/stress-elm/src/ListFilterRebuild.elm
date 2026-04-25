module ListFilterRebuild exposing (main)

-- CHECK: ListFilterRebuild: True

import StressHarness exposing (StressFlags)
import Task


cycle : List Int -> Bool
cycle original =
    let
        odds =
            List.filter (\x -> modBy 2 x == 1) original

        evens =
            List.filter (\x -> modBy 2 x == 0) original

        rebuilt =
            List.sort (odds ++ evens)
    in
    rebuilt == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            List.range 1 flags.maxSize
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ListFilterRebuild"
        , run = run
        }
