module DeepTreeMap exposing (main)

-- CHECK: DeepTreeMap: True

import StressHarness exposing (StressFlags)
import Task


type Tree
    = Leaf Int
    | Branch Tree Tree


buildTree : Int -> Int -> Tree
buildTree lo hi =
    if lo >= hi then
        Leaf lo

    else
        let
            mid =
                (lo + hi) // 2
        in
        Branch (buildTree lo mid) (buildTree (mid + 1) hi)


mapTree : (Int -> Int) -> Tree -> Tree
mapTree f tree =
    case tree of
        Leaf v ->
            Leaf (f v)

        Branch left right ->
            Branch (mapTree f left) (mapTree f right)


cycle : Tree -> Bool
cycle original =
    mapTree negate (mapTree negate original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildTree 1 flags.maxSize

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "DeepTreeMap"
        , run = run
        }
