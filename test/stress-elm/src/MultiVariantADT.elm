module MultiVariantADT exposing (main)

-- CHECK: MultiVariantADT: True

import StressHarness exposing (StressFlags)
import Task


type Shape
    = Point
    | Circle Int
    | Rect Int Int
    | Triangle Int Int Int
    | Quad Int Int Int Int


buildShapes : Int -> List Shape -> List Shape
buildShapes i acc =
    if i <= 0 then
        acc

    else
        let
            shape =
                case modBy 5 i of
                    0 ->
                        Point

                    1 ->
                        Circle i

                    2 ->
                        Rect i (i + 1)

                    3 ->
                        Triangle i (i + 1) (i + 2)

                    _ ->
                        Quad i (i + 1) (i + 2) (i + 3)
        in
        buildShapes (i - 1) (shape :: acc)


negateShape : Shape -> Shape
negateShape shape =
    case shape of
        Point ->
            Point

        Circle r ->
            Circle (-r)

        Rect w h ->
            Rect (-w) (-h)

        Triangle a b c ->
            Triangle (-a) (-b) (-c)

        Quad a b c d ->
            Quad (-a) (-b) (-c) (-d)


cycle : List Shape -> Bool
cycle original =
    List.map negateShape (List.map negateShape original) == original


run : StressFlags -> Task.Task Never Bool
run flags =
    let
        original =
            buildShapes flags.maxSize []

        loopCount =
            flags.numLoops // 2
    in
    StressHarness.loopWhile flags
        loopCount
        (\_ -> Task.succeed (cycle original))


main : Program StressFlags StressHarness.Model StressHarness.Msg
main =
    StressHarness.taskProgram
        { label = "MultiVariantADT"
        , run = run
        }
