module StringSplitJoin exposing (main)

-- CHECK: StringSplitJoin: True

import StressHarness exposing (StressFlags)
import Task


buildWords : Int -> List String -> List String
buildWords i acc =
    if i <= 0 then
        acc

    else
        buildWords (i - 1) (String.fromInt i :: acc)


cycle : String -> Bool
cycle original =
    String.join " " (String.words original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        words =
            buildWords flags.maxSize []

        original =
            String.join " " words
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "StringSplitJoin"
        , run = run
        }
