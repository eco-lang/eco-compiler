module BoolTrueFalseTest exposing (main)

{-| Test True and False constants.
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
