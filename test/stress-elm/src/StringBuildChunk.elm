module StringBuildChunk exposing (main)

-- CHECK: StringBuildChunk: True

import StressHarness exposing (StressFlags)
import Task


buildString : Int -> String -> String
buildString i acc =
    if i <= 0 then
        acc

    else
        buildString (i - 1) (acc ++ "abcd")


cycle : Int -> Bool
cycle size =
    String.length (buildString size "") == size * 4


run : StressFlags -> Task.Task Never Bool
run flags =
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle flags.maxSize))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "StringBuildChunk"
        , run = run
        }
