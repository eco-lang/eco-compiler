module CombinatorBSumMapTest exposing (main)

{-| The B combinator, built from S and K, composing `List.sum` with a partially applied `List.map`: the sum of `[ 1, 2, 3 ]` each plus one is 9.

`b` is the point-free definition `s (k s) k`, applied to library functions
rather than to functions defined in the module.

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
