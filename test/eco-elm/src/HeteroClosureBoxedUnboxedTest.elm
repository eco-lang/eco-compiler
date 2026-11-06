module HeteroClosureBoxedUnboxedTest exposing (main)

{-| Partial applications of two different functions, one that has been given a custom type value and one that has been given an `Int`, can be chosen by an `if` and then called.

`f` is `shapeBonus Circle` (chosen by `if True`), so `f 3` is 13. `g` is
`addN 7` (chosen by the `else` of `if False`), so `g 3` is 10.

## eco

Exercises the heterogeneous closure ABI: one closure captures a custom type
value, stored boxed as `!eco.value`, the other captures an `Int`, stored
unboxed as `i64`. Both are chosen dynamically and then called, so the call
site must read each capture with its own representation (only Int, Float and
Char are unboxed in closures, see the REP_* invariants in
design_docs/invariants.csv).

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
