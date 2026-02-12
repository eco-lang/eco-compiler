module HeteroClosureBoxedUnboxedTest exposing (main)

{-| Test heterogeneous closure ABI: boxed custom type (!eco.value) vs
unboxed Int (i64) captures chosen dynamically, then called.
-}

-- CHECK: boxed_cap: 13
-- CHECK: unboxed_cap: 10

import Html exposing (text)


type Shape
    = Circle
    | Square


shapeBonus : Shape -> Int -> Int
shapeBonus shape x =
    case shape of
        Circle ->
            x + 10

        Square ->
            x + 20


addN : Int -> Int -> Int
addN n x =
    n + x


main =
    let
        f =
            if True then
                shapeBonus Circle
            else
                addN 5

        _ = Debug.log "boxed_cap" (f 3)

        g =
            if False then
                shapeBonus Square
            else
                addN 7

        _ = Debug.log "unboxed_cap" (g 3)
    in
    text "done"
