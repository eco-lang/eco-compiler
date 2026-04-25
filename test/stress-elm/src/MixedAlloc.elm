module MixedAlloc exposing (main)

-- CHECK: MixedAlloc: True

import Dict exposing (Dict)
import Set exposing (Set)
import StressHarness exposing (StressFlags)
import Task


buildDict : Int -> Dict Int Int -> Dict Int Int
buildDict i acc =
    if i <= 0 then
        acc

    else
        buildDict (i - 1) (Dict.insert i (i * 3) acc)


buildClosures : Int -> List (Int -> Int) -> List (Int -> Int)
buildClosures i acc =
    if i <= 0 then
        acc

    else
        buildClosures (i - 1) ((\k x -> x + k) i :: acc)


foldClosures : List (Int -> Int) -> Int -> Int
foldClosures fns acc =
    case fns of
        [] ->
            acc

        f :: rest ->
            foldClosures rest (f acc)


cycle : Int -> Bool
cycle quarter =
    let
        dict =
            buildDict quarter Dict.empty

        dictSum =
            Dict.foldl (\_ v acc -> acc + v) 0 dict

        list =
            List.range 1 quarter

        listSum =
            List.foldl (+) 0 list

        set =
            Set.fromList (List.range 1 quarter)

        setSum =
            Set.foldl (+) 0 set

        closures =
            buildClosures quarter []

        closureSum =
            foldClosures closures 0

        expectedListSum =
            quarter * (quarter + 1) // 2

        expectedDictSum =
            expectedListSum * 3
    in
    dictSum == expectedDictSum && listSum == expectedListSum && setSum == expectedListSum && closureSum == expectedListSum


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        quarter =
            flags.maxSize // 4
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle quarter))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MixedAlloc"
        , run = run
        }
