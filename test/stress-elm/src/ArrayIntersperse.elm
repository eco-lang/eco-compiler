module ArrayIntersperse exposing (main)

-- CHECK: ArrayIntersperse: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


intersperse : a -> Array a -> Array a
intersperse sep arr =
    let
        step x acc =
            if Array.isEmpty acc then
                Array.push x acc

            else
                Array.push x (Array.push sep acc)
    in
    Array.foldl step Array.empty arr


cycle : Array Int -> Int -> Bool
cycle original size =
    let
        interspersed =
            intersperse 0 original

        len =
            Array.length interspersed

        expectedLen =
            size * 2 - 1

        filtered =
            Array.filter (\x -> x /= 0) interspersed
    in
    len == expectedLen && filtered == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            Array.initialize flags.maxSize (\i -> i + 1)
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle original flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ArrayIntersperse"
        , run = run
        }
