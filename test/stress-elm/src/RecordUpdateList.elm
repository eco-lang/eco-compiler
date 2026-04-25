module RecordUpdateList exposing (main)

-- CHECK: RecordUpdateList: True

import StressHarness exposing (StressFlags)
import Task


type alias Rec =
    { a : Int
    , b : Int
    , c : Int
    }


buildRecs : Int -> List Rec -> List Rec
buildRecs i acc =
    if i <= 0 then
        acc

    else
        buildRecs (i - 1) ({ a = i, b = i * 2, c = i * 3 } :: acc)


flipA : Rec -> Rec
flipA r =
    { r | a = -r.a }


cycle : List Rec -> Bool
cycle original =
    List.map flipA (List.map flipA original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildRecs flags.maxSize []

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "RecordUpdateList"
        , run = run
        }
