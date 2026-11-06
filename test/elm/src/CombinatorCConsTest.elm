module CombinatorCConsTest exposing (main)

{-| The C combinator, which swaps two arguments, built from S and K and applied to the cons operator: `c (::) [ 2, 3 ] 1` is `1 :: [ 2, 3 ]`.

`c` is the point-free definition `s (b b s) (k k)`, with `b = s (k s) k`.

-}

-- CHECK: result: [1,2,3]

import Html exposing (text)


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

c = s (b b s) (k k)


main =
    let
        _ = Debug.log "result" (c (::) [ 2, 3 ] 1)
    in
    text "done"
