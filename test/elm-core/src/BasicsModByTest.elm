module BasicsModByTest exposing (main)

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
