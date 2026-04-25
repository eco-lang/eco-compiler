module ListIntersperse exposing (main)

-- CHECK: ListIntersperse: True

import StressHarness exposing (StressFlags)
import Task


cycle : List Int -> Int -> Bool
cycle original size =
    let
        interspersed =
            List.intersperse 0 original

        len =
            List.length interspersed

        expectedLen =
            size * 2 - 1

        filtered =
            List.filter (\x -> x /= 0) interspersed
    in
    len == expectedLen && filtered == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            List.range 1 flags.maxSize
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle original flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ListIntersperse"
        , run = run
        }
