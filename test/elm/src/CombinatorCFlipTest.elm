module CombinatorCFlipTest exposing (main)

{-| The C combinator, which swaps two arguments, built from S and K: `c sub 10 3` is `sub 3 10`, which is -7.

`c` is the point-free definition `s (b b s) (k k)`, with `b = s (k s) k`.

-}

-- CHECK: result: -7

import Html exposing (text)


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

c = s (b b s) (k k)

sub x y = x - y


main =
    let
        _ = Debug.log "result" (c sub 10 3)
    in
    text "done"
