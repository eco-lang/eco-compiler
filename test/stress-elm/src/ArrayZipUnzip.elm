module ArrayZipUnzip exposing (main)

-- CHECK: ArrayZipUnzip: True

import Array exposing (Array)
import StressHarness exposing (StressFlags)
import Task


zip : Array Int -> Array Int -> Array ( Int, Int )
zip xs ys =
    let
        len =
            min (Array.length xs) (Array.length ys)
    in
    Array.initialize len
        (\i ->
            ( Maybe.withDefault 0 (Array.get i xs)
            , Maybe.withDefault 0 (Array.get i ys)
            )
        )


unzip : Array ( Int, Int ) -> ( Array Int, Array Int )
unzip pairs =
    ( Array.map Tuple.first pairs
    , Array.map Tuple.second pairs
    )


cycle : Array Int -> Array Int -> Bool
cycle as_ bs =
    let
        zipped =
            zip as_ bs

        ( as2, bs2 ) =
            unzip zipped
    in
    as_ == as2 && bs == bs2


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        size =
            flags.maxSize

        as_ =
            Array.initialize size (\i -> i + 1)

        bs =
            Array.initialize size (\i -> i + 1 + size)

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle as_ bs))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ArrayZipUnzip"
        , run = run
        }
