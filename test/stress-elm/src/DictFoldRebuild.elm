module DictFoldRebuild exposing (main)

-- CHECK: DictFoldRebuild: True

import Dict exposing (Dict)
import StressHarness exposing (StressFlags)
import Task


buildDict : Int -> Dict Int Int -> Dict Int Int
buildDict i acc =
    if i <= 0 then
        acc

    else
        buildDict (i - 1) (Dict.insert i i acc)


rebuildWithTransform : Dict Int Int -> Dict Int Int
rebuildWithTransform d =
    Dict.foldl (\k v acc -> Dict.insert k (-v) acc) Dict.empty d


cycle : Dict Int Int -> Dict Int Int
cycle d =
    rebuildWithTransform (rebuildWithTransform d)


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
        (\_ -> Task.succeed (cycle original == original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "DictFoldRebuild"
        , run = run
        }
