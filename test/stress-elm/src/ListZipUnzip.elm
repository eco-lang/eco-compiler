module ListZipUnzip exposing (main)

-- CHECK: ListZipUnzip: True

import StressHarness exposing (StressFlags)
import Task


zip : List a -> List b -> List ( a, b ) -> List ( a, b )
zip xs ys acc =
    case ( xs, ys ) of
        ( x :: xr, y :: yr ) ->
            zip xr yr (( x, y ) :: acc)

        _ ->
            List.reverse acc


unzip : List ( a, b ) -> ( List a, List b )
unzip pairs =
    unzipHelper pairs [] []


unzipHelper : List ( a, b ) -> List a -> List b -> ( List a, List b )
unzipHelper pairs accA accB =
    case pairs of
        [] ->
            ( List.reverse accA, List.reverse accB )

        ( a, b ) :: rest ->
            unzipHelper rest (a :: accA) (b :: accB)


cycle : List Int -> List Int -> Bool
cycle as_ bs =
    let
        zipped =
            zip as_ bs []

        ( as2, bs2 ) =
            unzip zipped
    in
    as_ == as2 && bs == bs2


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        as_ =
            List.range 1 flags.maxSize

        bs =
            List.range (flags.maxSize + 1) (flags.maxSize * 2)
    in
    StressHarness.loopWhile flags
        flags.numLoops
        (\_ -> Task.succeed (cycle as_ bs))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "ListZipUnzip"
        , run = run
        }
