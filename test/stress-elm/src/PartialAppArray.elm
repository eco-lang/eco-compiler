module PartialAppArray exposing (main)

-- CHECK: PartialAppArray: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b + c


buildPartials : Int -> Array (Int -> Int -> Int)
buildPartials count =
    Array.initialize count (\i -> add3 (i + 1))


applyAll : Array (Int -> Int -> Int) -> Int -> Int
applyAll paps acc =
    Array.foldl (\f a -> a + f 0 0) acc paps


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        partials =
            buildPartials flags.maxSize

        expectedPerCycle =
            flags.maxSize * (flags.maxSize + 1) // 2
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (applyAll partials 0 == expectedPerCycle))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "PartialAppArray"
        , run = run
        }
