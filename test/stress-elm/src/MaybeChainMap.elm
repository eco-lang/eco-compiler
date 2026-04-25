module MaybeChainMap exposing (main)

-- CHECK: MaybeChainMap: True

import StressHarness exposing (StressFlags)
import Task


buildMaybes : Int -> List (Maybe Int) -> List (Maybe Int)
buildMaybes i acc =
    if i <= 0 then
        acc

    else
        buildMaybes (i - 1) (Just i :: acc)


negate_ : Int -> Int
negate_ x =
    -x


cycle : List (Maybe Int) -> Bool
cycle original =
    List.map (Maybe.map negate_) (List.map (Maybe.map negate_) original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildMaybes flags.maxSize []

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MaybeChainMap"
        , run = run
        }
