module CombinatorCConsTest exposing (main)

{-| C combinator with cons: c (::) [2,3] 1 = [1,2,3]
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
