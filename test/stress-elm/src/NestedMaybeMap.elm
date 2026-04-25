module NestedMaybeMap exposing (main)

-- CHECK: NestedMaybeMap: True

import StressHarness exposing (StressFlags)
import Task


buildTripleMaybes : Int -> List (Maybe (Maybe (Maybe Int))) -> List (Maybe (Maybe (Maybe Int)))
buildTripleMaybes i acc =
    if i <= 0 then
        acc

    else
        buildTripleMaybes (i - 1) (Just (Just (Just i)) :: acc)


tripleNestedNegate : Maybe (Maybe (Maybe Int)) -> Maybe (Maybe (Maybe Int))
tripleNestedNegate =
    Maybe.map (Maybe.map (Maybe.map negate))


cycle : List (Maybe (Maybe (Maybe Int))) -> Bool
cycle original =
    List.map tripleNestedNegate (List.map tripleNestedNegate original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildTripleMaybes flags.maxSize []

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "NestedMaybeMap"
        , run = run
        }
