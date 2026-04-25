module ArrayReverse exposing (main)

-- CHECK: ArrayReverse: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


reverse : Array a -> Array a
reverse arr =
    Array.foldl Array.push Array.empty arr


reverseNTimes : Int -> Array a -> Array a
reverseNTimes count arr =
    if count <= 0 then
        arr

    else
        reverseNTimes (count - 1) (reverse arr)


cycle : Int -> Int -> Bool
cycle size depth =
    let
        original =
            Array.initialize size (\i -> i + 1)

        finished =
            reverseNTimes depth original
    in
    finished == original


run : StressFlags -> Task.Task Never Bool
run flags =
    Task.succeed (cycle flags.maxSize (2 * (flags.numLoops // 2)))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ArrayReverse"
        , run = run
        }
