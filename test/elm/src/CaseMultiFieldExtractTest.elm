module CaseMultiFieldExtractTest exposing (main)

{-| Test case extracting multiple fields from custom type constructors.
-}

-- CHECK: point1: 3
-- CHECK: point2: 6
-- CHECK: rect1: 50

import Html exposing (text)


type Shape
    = Point Int Int
    | Rectangle Int Int Int Int


sumCoords shape =
    case shape of
        Point x y -> x + y
        Rectangle x1 y1 x2 y2 -> (x2 - x1) * (y2 - y1)


main =
    let
        _ = Debug.log "point1" (sumCoords (Point 1 2))
        _ = Debug.log "point2" (sumCoords (Point 2 4))
        _ = Debug.log "rect1" (sumCoords (Rectangle 0 0 10 5))
    in
    text "done"
