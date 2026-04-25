module PartialAppList exposing (main)

-- CHECK: PartialAppList: True

import StressHarness exposing (StressFlags)
import Task


add3 : Int -> Int -> Int -> Int
add3 a b c =
    a + b + c


buildPartials : Int -> List (Int -> Int -> Int) -> List (Int -> Int -> Int)
buildPartials i acc =
    if i <= 0 then
        acc

    else
        buildPartials (i - 1) (add3 i :: acc)


applyAll : List (Int -> Int -> Int) -> Int -> Int
applyAll paps acc =
    case paps of
        [] ->
            acc

        f :: rest ->
            applyAll rest (acc + f 0 0)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        partials =
            buildPartials flags.maxSize []

        expectedPerCycle =
            flags.maxSize * (flags.maxSize + 1) // 2
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (applyAll partials 0 == expectedPerCycle))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "PartialAppList"
        , run = run
        }
