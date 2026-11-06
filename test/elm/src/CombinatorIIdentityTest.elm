module CombinatorIIdentityTest exposing (main)

{-| The I combinator, identity, written as `s k k`: `i 42` is 42.

`s k k x` is `k x (k x)`, which is `x`.

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
