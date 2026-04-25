module TupleMapList exposing (main)

-- CHECK: TupleMapList: True

import StressHarness exposing (StressFlags)
import Task


buildTuples : Int -> List ( Int, Int ) -> List ( Int, Int )
buildTuples i acc =
    if i <= 0 then
        acc

    else
        buildTuples (i - 1) (( i, -i ) :: acc)


swap : ( a, b ) -> ( b, a )
swap ( a, b ) =
    ( b, a )


cycle : List ( Int, Int ) -> Bool
cycle original =
    List.map swap (List.map swap original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildTuples flags.maxSize []

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "TupleMapList"
        , run = run
        }
