module IntModByTest exposing (main)

{-| Checks that `modBy` with a positive modulus gives a non-negative result for a positive, a negative and a zero dividend.

`modBy 4 -7` is 1, not -3: the result takes the sign of the modulus, as with
floored division. The `mod3` and `mod4` lines repeat the arguments of `mod1` and
`mod2`.

Among what is not tested: a negative modulus, and `modBy 0`.

-}

-- CHECK: mod1: 3
-- CHECK: mod2: 1
-- CHECK: mod3: 3
-- CHECK: mod4: 1
-- CHECK: mod5: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "mod1" (modBy 4 7)
        _ = Debug.log "mod2" (modBy 4 -7)
        _ = Debug.log "mod3" (modBy 4 7)
        _ = Debug.log "mod4" (modBy 4 -7)
        _ = Debug.log "mod5" (modBy 5 0)
    in
    text "done"
