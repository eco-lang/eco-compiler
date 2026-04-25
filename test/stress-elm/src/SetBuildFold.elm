module SetBuildFold exposing (main)

-- CHECK: SetBuildFold: True

import Set exposing (Set)
import StressHarness exposing (StressFlags)
import Task


buildSet : Int -> Set Int -> Set Int
buildSet i acc =
    if i <= 0 then
        acc

    else
        buildSet (i - 1) (Set.insert i acc)


cycle : Int -> Int
cycle size =
    Set.foldl (+) 0 (buildSet size Set.empty)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount =
            flags.numLoops // 2

        expectedPerCycle =
            flags.maxSize * (flags.maxSize + 1) // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle flags.maxSize == expectedPerCycle))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "SetBuildFold"
        , run = run
        }
