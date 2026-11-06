module CombinatorTPipeTest exposing (main)

{-| The T combinator, built from S and K, passing `[ 1, 2, 3 ]` to the composition of `List.sum` and `List.map ((*) 2)`: the result is 12.

`t` is `c i`, where `c = s (b b s) (k k)`, `b = s (k s) k` and `i = s k k`.

-}

-- CHECK: result: 12

import Html exposing (text)


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

c = s (b b s) (k k)

i = s k k

t = c i


main =
    let
        _ = Debug.log "result" (t [ 1, 2, 3 ] (b List.sum (List.map ((*) 2))))
    in
    text "done"
