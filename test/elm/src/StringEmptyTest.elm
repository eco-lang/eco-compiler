module StringEmptyTest exposing (main)

{-| The empty string literal prints as `""` and `String.isEmpty ""` is `True`.
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
