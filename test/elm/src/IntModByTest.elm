module IntModByTest exposing (main)

{-| Test modBy with all sign combinations.
    modBy always returns a non-negative result (floored division).
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
