module RecordWithFunctionsTest exposing (main)

{-| Test records containing function values in fields. -}

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
