module ClosureCaptureVary exposing (main)

-- CHECK: ClosureCaptureVary: True

import StressHarness exposing (StressFlags)
import Task


buildClosures : Int -> List (Int -> Int) -> List (Int -> Int)
buildClosures i acc =
    if i <= 0 then
        acc

    else
        let
            kind =
                modBy 5 i

            closure =
                case kind of
                    0 ->
                        \x -> x + i

                    1 ->
                        \x -> x + i + kind

                    2 ->
                        \x -> x + i * 2

                    3 ->
                        \x -> x + i - kind

                    _ ->
                        \x -> x + i + 1
        in
        buildClosures (i - 1) (closure :: acc)


applyAll : List (Int -> Int) -> Int -> Int
applyAll fns acc =
    case fns of
        [] ->
            acc

        f :: rest ->
            applyAll rest (f acc)


cycle : List (Int -> Int) -> Int -> Bool
cycle closures expected =
    applyAll closures 0 == expected


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        closures =
            buildClosures flags.maxSize []

        expected =
            applyAll closures 0
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle closures expected))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ClosureCaptureVary"
        , run = run
        }
