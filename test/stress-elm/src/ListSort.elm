module ListSort exposing (main)

-- CHECK: ListSort: True

import StressHarness exposing (StressFlags)
import Task


cycle : List Int -> Bool
cycle sorted =
    List.sort (List.reverse sorted) == sorted


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        sorted =
            List.range 1 flags.maxSize
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle sorted))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ListSort"
        , run = run
        }
