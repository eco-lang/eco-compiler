module DictUnionDiff exposing (main)

-- CHECK: DictUnionDiff: True

import Dict exposing (Dict)
import StressHarness exposing (StressFlags)
import Task


buildDict : Int -> Int -> Dict Int Int -> Dict Int Int
buildDict lo hi acc =
    if lo > hi then
        acc

    else
        buildDict (lo + 1) hi (Dict.insert lo (lo * 10) acc)


cycle : Dict Int Int -> Dict Int Int -> Int -> Int -> Bool
cycle left right size half =
    let
        merged =
            Dict.union left right

        diffed =
            Dict.diff merged right
    in
    Dict.size merged == size && Dict.size diffed == half


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        m =
            flags.maxSize

        half =
            m // 2

        loopCount =
            flags.numLoops // 4

        left =
            buildDict 1 half Dict.empty

        right =
            buildDict (half + 1) m Dict.empty
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle left right m half))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "DictUnionDiff"
        , run = run
        }
