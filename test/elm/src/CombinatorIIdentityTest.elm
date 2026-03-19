module CombinatorIIdentityTest exposing (main)

{-| I combinator (identity via S K K): i 42 = 42
-}

-- CHECK: result: 42

import Html exposing (text)


k a _ = a

s bf uf x = bf x (uf x)

i = s k k


main =
    let
        _ = Debug.log "result" (i 42)
    in
    text "done"
