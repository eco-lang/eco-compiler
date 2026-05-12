module NotEqualBoolVarTest exposing (main)

{-| Same 2x2 as `NotEqualBoolTest` but operands flow through let-bound
variables and a non-inlinable helper. If constant folding ever collapsed
literal `True /= False` to True upstream, this form would still reach
the runtime kernel.
-}

-- CHECK: vTT: False
-- CHECK: vTF: True
-- CHECK: vFT: True
-- CHECK: vFF: False
-- CHECK: hTT: False
-- CHECK: hTF: True
-- CHECK: hFT: True
-- CHECK: hFF: False

import Html exposing (text)


neqBool : Bool -> Bool -> Bool
neqBool a b =
    a /= b


main =
    let
        t = True
        f = False

        _ = Debug.log "vTT" (t /= t)
        _ = Debug.log "vTF" (t /= f)
        _ = Debug.log "vFT" (f /= t)
        _ = Debug.log "vFF" (f /= f)

        _ = Debug.log "hTT" (neqBool True True)
        _ = Debug.log "hTF" (neqBool True False)
        _ = Debug.log "hFT" (neqBool False True)
        _ = Debug.log "hFF" (neqBool False False)
    in
    text "done"
