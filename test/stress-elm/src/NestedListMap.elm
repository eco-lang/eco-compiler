module NestedListMap exposing (main)

-- CHECK: NestedListMap: True

import StressHarness exposing (StressFlags)
import Task


innerSize : Int
innerSize =
    10


buildNested : Int -> List (List Int) -> List (List Int)
buildNested i acc =
    if i <= 0 then
        acc

    else
        buildNested (i - 1) (List.range ((i - 1) * innerSize + 1) (i * innerSize) :: acc)


cycle : List (List Int) -> Bool
cycle original =
    List.map (List.map negate) (List.map (List.map negate) original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        outerCount =
            flags.maxSize // innerSize

        original =
            buildNested outerCount []

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "NestedListMap"
        , run = run
        }
