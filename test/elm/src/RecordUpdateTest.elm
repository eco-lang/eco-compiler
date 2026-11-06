module RecordUpdateTest exposing (main)

{-| Record update syntax produces a new record with one field changed and leaves the original unchanged.
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
