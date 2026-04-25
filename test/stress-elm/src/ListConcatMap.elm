module ListConcatMap exposing (main)

-- CHECK: ListConcatMap: True

import StressHarness exposing (StressFlags)
import Task


cycle : Int -> Bool
cycle size =
    let
        original =
            List.range 1 size

        expanded =
            List.concatMap (\x -> [ x, x + size, x + size * 2 ]) original
    in
    List.length expanded == size * 3


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ListConcatMap"
        , run = run
        }
