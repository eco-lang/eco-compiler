module BoolAndTest exposing (main)

{-| The `&&` operator gives `True` only when both operands are `True`, checked over all four combinations.
-}

-- CHECK: and1: True
-- CHECK: and2: False
-- CHECK: and3: False
-- CHECK: and4: False

import Html exposing (text)


main =
    let
        _ = Debug.log "and1" (True && True)
        _ = Debug.log "and2" (True && False)
        _ = Debug.log "and3" (False && True)
        _ = Debug.log "and4" (False && False)
    in
    text "done"
