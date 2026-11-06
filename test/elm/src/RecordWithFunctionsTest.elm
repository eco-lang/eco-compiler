module RecordWithFunctionsTest exposing (main)

{-| Functions stored in record fields can be called, composed and replaced with record update.

`ops.add 10` gives 11, `ops.mul 10` gives 20 and `ops.mul (ops.add 10)` gives 22.
`ops2` replaces `add` with `\x -> x + 2`, so `ops2.add 5` gives 7.
-}

-- CHECK: apply1: 11
-- CHECK: apply2: 20
-- CHECK: composed: 22
-- CHECK: updated: 7

import Html exposing (text)


main =
    let
        ops = { add = \x -> x + 1, mul = \x -> x * 2 }
        _ = Debug.log "apply1" (ops.add 10)
        _ = Debug.log "apply2" (ops.mul 10)
        _ = Debug.log "composed" (ops.mul (ops.add 10))
        ops2 = { ops | add = \x -> x + 2 }
        _ = Debug.log "updated" (ops2.add 5)
    in
    text "done"
