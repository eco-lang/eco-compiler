module CombinatorPLengthsTest exposing (main)

{-| P combinator: add lengths of two lists = 5
-}

-- CHECK: result: 5

import Html exposing (text)


p bf uf x y = bf (uf x) (uf y)


main =
    let
        _ = Debug.log "result" (p (+) List.length [ 1, 2, 3 ] [ 4, 5 ])
    in
    text "done"
