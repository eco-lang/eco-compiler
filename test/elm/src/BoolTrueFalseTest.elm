module BoolTrueFalseTest exposing (main)

{-| The Bool constants `True` and `False` print as `True` and `False` with `Debug.log`.
-}

-- CHECK: true: True
-- CHECK: false: False

import Html exposing (text)


main =
    let
        _ = Debug.log "true" True
        _ = Debug.log "false" False
    in
    text "done"
