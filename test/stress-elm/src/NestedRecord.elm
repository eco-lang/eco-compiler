module NestedRecord exposing (main)

-- CHECK: NestedRecord: True

import StressHarness exposing (StressFlags)
import Task


type alias Inner =
    { x : Int
    , y : Int
    }


type alias Outer =
    { label : Int
    , inner : Inner
    }


buildRecords : Int -> List Outer -> List Outer
buildRecords i acc =
    if i <= 0 then
        acc

    else
        buildRecords (i - 1) ({ label = i, inner = { x = i, y = -i } } :: acc)


negateInner : Outer -> Outer
negateInner r =
    { r | inner = { x = -r.inner.x, y = -r.inner.y } }


cycle : List Outer -> Bool
cycle original =
    List.map negateInner (List.map negateInner original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildRecords flags.maxSize []

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "NestedRecord"
        , run = run
        }
