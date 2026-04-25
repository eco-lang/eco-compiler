module ListMapRoundtrip exposing (main)

-- CHECK: ListMapRoundtrip: True

import StressHarness exposing (StressFlags)
import Task


negate_ : Int -> Int
negate_ x =
    -x


cycle : List Int -> Bool
cycle original =
    List.map negate_ (List.map negate_ original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            List.range 1 flags.maxSize

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ListMapRoundtrip"
        , run = run
        }
