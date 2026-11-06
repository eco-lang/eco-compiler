module BasicsModByTest exposing (main)

{-| `modBy 3` gives 1 for 7, 0 for 9, and 2 for -1: the result takes the sign of the modulus,
not of the dividend.
-}

-- CHECK: mod_pos: 1
-- CHECK: mod_neg: 2
-- CHECK: mod_zero: 0

import Html exposing (text)

main =
    let
        _ = Debug.log "mod_pos" (modBy 3 7)
        _ = Debug.log "mod_neg" (modBy 3 -1)
        _ = Debug.log "mod_zero" (modBy 3 9)
    in
    text "done"
