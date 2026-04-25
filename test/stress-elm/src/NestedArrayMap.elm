module NestedArrayMap exposing (main)

-- CHECK: NestedArrayMap: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


innerSize : Int
innerSize =
    10


buildNested : Int -> Array (Array Int)
buildNested outerCount =
    Array.initialize outerCount
        (\i -> Array.initialize innerSize (\k -> i * innerSize + k + 1))


cycle : Array (Array Int) -> Bool
cycle original =
    Array.map (Array.map negate) (Array.map (Array.map negate) original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        outerCount =
            flags.maxSize // innerSize

        original =
            buildNested outerCount

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "NestedArrayMap"
        , run = run
        }
