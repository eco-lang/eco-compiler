module CombinatorSpMulTest exposing (main)

{-| SP combinator with operator sections: ((+) 1 x) * ((*) 2 x) at x=6 = 84
-}

-- CHECK: result: 84

import Html exposing (text)


sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)


main =
    let
        _ = Debug.log "result" (sp (*) ((+) 1) ((*) 2) 6)
    in
    text "done"
