module CombinatorTThrushTest exposing (main)

{-| The T combinator, which applies its second argument to its first, built from S and K: `t 7 (\x -> x * 3)` is 21.

`t` is `c i`, where `c = s (b b s) (k k)`, `b = s (k s) k` and `i = s k k`.

-}

-- CHECK: result: 21

import Html exposing (text)


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

c = s (b b s) (k k)

i = s k k

t = c i


main =
    let
        _ = Debug.log "result" (t 7 (\x -> x * 3))
    in
    text "done"
