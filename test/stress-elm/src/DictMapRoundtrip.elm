module DictMapRoundtrip exposing (main)

-- CHECK: DictMapRoundtrip: True

import Dict exposing (Dict)
import StressHarness exposing (StressFlags)
import Task


buildDict : Int -> Dict Int String -> Dict Int String
buildDict i acc =
    if i <= 0 then
        acc

    else
        buildDict (i - 1) (Dict.insert i (String.fromInt i) acc)


cycle : Dict Int String -> Bool
cycle original =
    Dict.map (\_ v -> String.reverse v) (Dict.map (\_ v -> String.reverse v) original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildDict flags.maxSize Dict.empty

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "DictMapRoundtrip"
        , run = run
        }
