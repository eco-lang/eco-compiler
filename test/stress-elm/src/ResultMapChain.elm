module ResultMapChain exposing (main)

-- CHECK: ResultMapChain: True

import StressHarness exposing (StressFlags)
import Task


buildResults : Int -> List (Result String Int) -> List (Result String Int)
buildResults i acc =
    if i <= 0 then
        acc

    else
        let
            val =
                if modBy 2 i == 0 then
                    Ok i

                else
                    Err (String.fromInt i)
        in
        buildResults (i - 1) (val :: acc)


cycle : List (Result String Int) -> Bool
cycle original =
    List.map (Result.map negate) (List.map (Result.map negate) original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildResults flags.maxSize []

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ResultMapChain"
        , run = run
        }
