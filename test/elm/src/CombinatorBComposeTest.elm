module CombinatorBComposeTest exposing (main)

{-| The B combinator, function composition, built only from S and K: `b square inc 4` is `square (inc 4)`, which is 25.

`k` returns its first argument, `s bf uf x` is `bf x (uf x)`, and `b` is the
point-free definition `s (k s) k`.

-}

-- CHECK: result: 25

import Html exposing (text)


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

inc x = x + 1
square x = x * x


main =
    let
        _ = Debug.log "result" (b square inc 4)
    in
    text "done"
