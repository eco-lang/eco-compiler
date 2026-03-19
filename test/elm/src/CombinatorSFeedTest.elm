module CombinatorSFeedTest exposing (main)

{-| S combinator: x + double x on 5 = 15
-}

-- CHECK: result: 15

import Html exposing (text)


s bf uf x = bf x (uf x)

double x = x * 2


main =
    let
        _ = Debug.log "result" (s (+) double 5)
    in
    text "done"
