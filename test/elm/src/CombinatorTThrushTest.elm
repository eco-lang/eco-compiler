module CombinatorTThrushTest exposing (main)

{-| T combinator (thrush): pipe 7 into (\x -> x * 3) = 21
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
