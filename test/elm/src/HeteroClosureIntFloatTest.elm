module HeteroClosureIntFloatTest exposing (main)

{-| Partial applications of two different functions, one that has been given an `Int` and one that has been given a `Float`, can be chosen by an `if` and then called.

Both have type `Int -> Int`. `f` is `addN 10`, so `f 3` is 13. `g` is
`mulF 2.5`, so `g 4` is `truncate 10.0`, which is 10.

-}

-- CHECK: hetero_true: 13
-- CHECK: hetero_false: 10

import Html exposing (text)


addN : Int -> Int -> Int
addN n x =
    n + x


mulF : Float -> Int -> Int
mulF f x =
    truncate (f * toFloat x)


main =
    let
        f =
            if True then
                addN 10
            else
                mulF 2.5

        _ = Debug.log "hetero_true" (f 3)

        g =
            if False then
                addN 10
            else
                mulF 2.5

        _ = Debug.log "hetero_false" (g 4)
    in
    text "done"
