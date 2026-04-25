module ClosureAccum exposing (main)

-- CHECK: ClosureAccum: True

import StressHarness exposing (StressFlags)
import Task


buildClosures : Int -> List (Int -> Int) -> List (Int -> Int)
buildClosures i acc =
    if i <= 0 then
        acc

    else
        buildClosures (i - 1) ((\k x -> x + k) i :: acc)


applyAll : List (Int -> Int) -> Int -> Int
applyAll fns acc =
    case fns of
        [] ->
            acc

        f :: rest ->
            applyAll rest (f acc)


cycle : List (Int -> Int) -> Int -> Int
cycle closures acc =
    applyAll closures acc


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        closures =
            buildClosures flags.maxSize []

        expectedPerCycle =
            flags.maxSize * (flags.maxSize + 1) // 2
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle closures 0 == expectedPerCycle))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ClosureAccum"
        , run = run
        }
