module CombinatorBSumMapTest exposing (main)

{-| B combinator with List.sum and List.map: sum (map ((+) 1) [1,2,3]) = 9
-}

-- CHECK: result: 9

import Html exposing (text)


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k


main =
    let
        _ = Debug.log "result" (b List.sum (List.map ((+) 1)) [ 1, 2, 3 ])
    in
    text "done"
