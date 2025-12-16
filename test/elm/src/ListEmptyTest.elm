module ListEmptyTest exposing (main)

{-| Test empty list.
-}

-- CHECK: empty: []
-- CHECK: isEmpty: True

import Html exposing (text)


main =
    let
        _ = Debug.log "empty" []
        _ = Debug.log "isEmpty" (List.isEmpty [])
    in
    text "done"
