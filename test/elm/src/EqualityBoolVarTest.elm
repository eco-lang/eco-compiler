module EqualityBoolVarTest exposing (main)

{-| `==` on `Bool` values gives the correct answer when the operands are
variables or arguments rather than literals.

The first four cases compare the `let`-bound variables `t` and `f`; the other
four pass literals to `eqBool`, a top-level function that compares its two
arguments with `==`. Each set covers all four combinations, and only equal
operands give `True`.

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
