module MultiVariantADT exposing (main)

-- CHECK: roundtrip: True

import Html exposing (text)


n : Int
n =
    1000


m : Int
m =
    1000


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


applyNTimes : Int -> (a -> a) -> a -> a
applyNTimes count f val =
    if count <= 0 then
        val
    else
        applyNTimes (count - 1) f (f val)


main =
    let
        original =
            buildShapes m []

        transformed =
            applyNTimes n (List.map negateShape) original

        roundtrip =
            original == transformed

        _ =
            Debug.log "roundtrip" roundtrip
    in
    text "done"
