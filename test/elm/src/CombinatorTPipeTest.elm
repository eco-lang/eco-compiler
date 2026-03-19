module CombinatorTPipeTest exposing (main)

{-| T combinator: pipe [1,2,3] into (sum << map ((*) 2)) = 12
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
