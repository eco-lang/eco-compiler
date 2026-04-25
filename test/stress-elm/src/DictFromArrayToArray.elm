module DictFromArrayToArray exposing (main)

-- CHECK: DictFromArrayToArray: True

import Array exposing (Array)
import Dict exposing (Dict)
import StressHarness exposing (StressFlags)
import Task


buildPairs : Int -> Array ( Int, Int )
buildPairs count =
    Array.initialize count
        (\i ->
            let
                k =
                    i + 1
            in
            ( k, k * 7 )
        )


cycle : Array ( Int, Int ) -> Bool
cycle original =
    let
        dict =
            original |> Array.toList |> Dict.fromList

        back =
            dict |> Dict.toList |> Array.fromList
    in
    back == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildPairs flags.maxSize

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "DictFromArrayToArray"
        , run = run
        }
