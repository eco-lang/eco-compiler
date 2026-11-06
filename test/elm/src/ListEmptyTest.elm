module ListEmptyTest exposing (main)

{-| The empty list `[]` logs as `[]` and `List.isEmpty []` is `True`.
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
