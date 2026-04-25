module RecordUpdateArray exposing (main)

-- CHECK: RecordUpdateArray: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


type alias Rec =
    { a : Int
    , b : Int
    , c : Int
    }


buildRecs : Int -> Array Rec
buildRecs count =
    Array.initialize count
        (\i ->
            let
                k =
                    i + 1
            in
            { a = k, b = k * 2, c = k * 3 }
        )


flipA : Rec -> Rec
flipA r =
    { r | a = -r.a }


cycle : Array Rec -> Bool
cycle original =
    Array.map flipA (Array.map flipA original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildRecs flags.maxSize

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "RecordUpdateArray"
        , run = run
        }
