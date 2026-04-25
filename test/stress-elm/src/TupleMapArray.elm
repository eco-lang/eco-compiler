module TupleMapArray exposing (main)

-- CHECK: TupleMapArray: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


buildTuples : Int -> Array ( Int, Int )
buildTuples count =
    Array.initialize count (\i -> ( i + 1, -(i + 1) ))


swap : ( a, b ) -> ( b, a )
swap ( a, b ) =
    ( b, a )


cycle : Array ( Int, Int ) -> Bool
cycle original =
    Array.map swap (Array.map swap original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildTuples flags.maxSize

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "TupleMapArray"
        , run = run
        }
