module CombinatorSpCombineTest exposing (main)

{-| SP combinator: (inc x) * (double x) on 6 = 84
-}

-- CHECK: result: 84

import Html exposing (text)


sp bf uf1 uf2 x = bf (uf1 x) (uf2 x)

inc x = x + 1
double x = x * 2
mul x y = x * y


main =
    let
        _ = Debug.log "result" (sp mul inc double 6)
    in
    text "done"
