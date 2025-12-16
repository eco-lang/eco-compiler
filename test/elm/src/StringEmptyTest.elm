module StringEmptyTest exposing (main)

{-| Test empty string.
-}

-- CHECK: empty: ""
-- CHECK: isEmpty: True

import Html exposing (text)


main =
    let
        _ = Debug.log "empty" ""
        _ = Debug.log "isEmpty" (String.isEmpty "")
    in
    text "done"
