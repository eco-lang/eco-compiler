module CaseCustomTypeTest exposing (main)

{-| Test case on custom types.
-}

-- CHECK: shape1: 100
-- CHECK: shape2: 50

import Html exposing (text)


type Shape
    = Circle Int
    | Rectangle Int Int


area shape =
    case shape of
        Circle r -> r * r
        Rectangle w h -> w * h


main =
    let
        _ = Debug.log "shape1" (area (Circle 10))
        _ = Debug.log "shape2" (area (Rectangle 5 10))
    in
    text "done"
