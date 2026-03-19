module CombinatorCFlipTest exposing (main)

{-| C combinator (flip): flipped subtraction on 10 and 3 = -7
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
