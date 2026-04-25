module DictFromListToList exposing (main)

-- CHECK: DictFromListToList: True

import Dict exposing (Dict)
import StressHarness exposing (StressFlags)
import Task


buildPairs : Int -> List ( Int, Int ) -> List ( Int, Int )
buildPairs i acc =
    if i <= 0 then
        acc

    else
        buildPairs (i - 1) (( i, i * 7 ) :: acc)


cycle : List ( Int, Int ) -> Bool
cycle original =
    Dict.toList (Dict.fromList original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildPairs flags.maxSize []

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "DictFromListToList"
        , run = run
        }
