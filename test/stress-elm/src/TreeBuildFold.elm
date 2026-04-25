module TreeBuildFold exposing (main)

-- CHECK: TreeBuildFold: True

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


foldTree : (Int -> a -> a) -> a -> Tree -> a
foldTree f acc tree =
    case tree of
        Leaf v ->
            f v acc

        Branch left right ->
            foldTree f (foldTree f acc left) right


cycle : Int -> Int
cycle size =
    foldTree (+) 0 (buildTree 1 size)


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        expectedPerCycle =
            flags.maxSize * (flags.maxSize + 1) // 2
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle flags.maxSize == expectedPerCycle))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "TreeBuildFold"
        , run = run
        }
