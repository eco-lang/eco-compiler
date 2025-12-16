module RecordUpdateTest exposing (main)

{-| Test record update syntax.
-}

-- CHECK: updated: { x = 10, y = 2 }
-- CHECK: original: { x = 1, y = 2 }

import Html exposing (text)


main =
    let
        original = { x = 1, y = 2 }
        updated = { original | x = 10 }
        _ = Debug.log "updated" updated
        _ = Debug.log "original" original
    in
    text "done"
