module ArraySort exposing (main)

-- CHECK: ArraySort: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


reverse : Array a -> Array a
reverse arr =
    Array.foldl Array.push Array.empty arr


sortArray : Array comparable -> Array comparable
sortArray arr =
    arr |> Array.toList |> List.sort |> Array.fromList


cycle : Array Int -> Bool
cycle sorted =
    sortArray (reverse sorted) == sorted


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        sorted =
            Array.initialize flags.maxSize (\i -> i + 1)
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle sorted))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ArraySort"
        , run = run
        }
