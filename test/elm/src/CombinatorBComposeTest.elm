module CombinatorBComposeTest exposing (main)

{-| B combinator (compose): square << inc on 4 = 25
-}

-- CHECK: result: 25

import Html exposing (text)


k a _ = a

s bf uf x = bf x (uf x)

b = s (k s) k

inc x = x + 1
square x = x * x


main =
    let
        _ = Debug.log "result" (b square inc 4)
    in
    text "done"
