module ArrayMapRoundtrip exposing (main)

-- CHECK: ArrayMapRoundtrip: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


negate_ : Int -> Int
negate_ x =
    -x


cycle : Array Int -> Bool
cycle original =
    Array.map negate_ (Array.map negate_ original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            Array.initialize flags.maxSize (\i -> i + 1)

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ArrayMapRoundtrip"
        , run = run
        }
