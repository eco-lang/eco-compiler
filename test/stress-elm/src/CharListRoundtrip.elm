module CharListRoundtrip exposing (main)

-- CHECK: CharListRoundtrip: True

import StressHarness exposing (StressFlags)
import Task


buildString : Int -> String -> String
buildString i acc =
    if i <= 0 then
        acc

    else
        buildString (i - 1) (acc ++ "x")


cycle : String -> Bool
cycle original =
    let
        chars =
            String.toList original

        uppered =
            List.map Char.toUpper chars

        lowered =
            List.map Char.toLower uppered

        rebuilt =
            String.fromList lowered
    in
    rebuilt == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildString flags.maxSize ""
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "CharListRoundtrip"
        , run = run
        }
