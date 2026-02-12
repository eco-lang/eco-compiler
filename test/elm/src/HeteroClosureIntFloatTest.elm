module HeteroClosureIntFloatTest exposing (main)

{-| Test heterogeneous closure ABI: Int (i64) vs Float (f64) captures
chosen dynamically, then called through the same call site.
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
