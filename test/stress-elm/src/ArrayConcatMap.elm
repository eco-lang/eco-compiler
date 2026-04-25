module ArrayConcatMap exposing (main)

-- CHECK: ArrayConcatMap: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


concatMap : (a -> Array b) -> Array a -> Array b
concatMap f arr =
    Array.foldl (\x acc -> Array.append acc (f x)) Array.empty arr


cycle : Int -> Bool
cycle size =
    let
        original =
            Array.initialize size (\i -> i + 1)

        expanded =
            concatMap (\x -> Array.fromList [ x, x + size, x + size * 2 ]) original
    in
    Array.length expanded == size * 3


run : StressFlags -> Task.Task Never Bool
run flags =
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ArrayConcatMap"
        , run = run
        }
