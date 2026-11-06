module CombinatorSFeedTest exposing (main)

{-| The S combinator, which gives its argument to a function together with a second function's result on that argument: `s (+) double 5` is `5 + double 5`, which is 15.
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
