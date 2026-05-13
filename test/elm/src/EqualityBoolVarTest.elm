module EqualityBoolVarTest exposing (main)

{-| Same 2x2 as EqualityBoolTest but operands flow through `let`-bound
variables and a non-inlinable helper. If constant folding were ever to
collapse literal `True == False` to `False` upstream of the kernel call,
this form would still go through the runtime path.
-}

-- CHECK: vTT: True
-- CHECK: vTF: False
-- CHECK: vFT: False
-- CHECK: vFF: True
-- CHECK: hTT: True
-- CHECK: hTF: False
-- CHECK: hFT: False
-- CHECK: hFF: True

import Html exposing (text)


eqBool : Bool -> Bool -> Bool
eqBool a b =
    a == b


main =
    let
        t = True
        f = False

        _ = Debug.log "vTT" (t == t)
        _ = Debug.log "vTF" (t == f)
        _ = Debug.log "vFT" (f == t)
        _ = Debug.log "vFF" (f == f)

        _ = Debug.log "hTT" (eqBool True True)
        _ = Debug.log "hTF" (eqBool True False)
        _ = Debug.log "hFT" (eqBool False True)
        _ = Debug.log "hFF" (eqBool False False)
    in
    text "done"
