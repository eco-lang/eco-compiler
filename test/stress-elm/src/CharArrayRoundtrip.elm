module CharArrayRoundtrip exposing (main)

-- CHECK: CharArrayRoundtrip: True

import Array exposing (Array)
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
            original |> String.toList |> Array.fromList

        uppered =
            Array.map Char.toUpper chars

        lowered =
            Array.map Char.toLower uppered

        rebuilt =
            lowered |> Array.toList |> String.fromList
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
        { label = "CharArrayRoundtrip"
        , run = run
        }
