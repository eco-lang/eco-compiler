module NotEqualBoolVarTest exposing (main)

{-| `/=` gives the right answer on `Bool` values held in `let`-bound
variables, and inside a top-level helper `neqBool` that receives both
operands as arguments, for all four combinations of operands.
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
