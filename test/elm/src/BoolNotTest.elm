module BoolNotTest exposing (main)

{-| `not` negates a Bool: `not True` is `False` and `not False` is `True`.
-}

-- CHECK: not1: False
-- CHECK: not2: True

import Html exposing (text)


main =
    let
        _ = Debug.log "not1" (not True)
        _ = Debug.log "not2" (not False)
    in
    text "done"
