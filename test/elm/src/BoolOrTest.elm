module BoolOrTest exposing (main)

{-| The `||` operator gives `False` only when both operands are `False`, checked over all four combinations.
-}

-- CHECK: or1: True
-- CHECK: or2: True
-- CHECK: or3: True
-- CHECK: or4: False

import Html exposing (text)


main =
    let
        _ = Debug.log "or1" (True || True)
        _ = Debug.log "or2" (True || False)
        _ = Debug.log "or3" (False || True)
        _ = Debug.log "or4" (False || False)
    in
    text "done"
