module EqualityBoolRecordTest exposing (main)

{-| Record equality compares `Bool` fields correctly.

The record `ref` is `{ a = True, b = False }`. It equals a separately written
record with the same fields, and differs from records that flip `a`, flip `b` or
flip both. `recFF_FF` compares a record with both fields `False` against a
literal with the same fields, which is `True`.

-}

-- CHECK: recEq: True
-- CHECK: recDiffA: False
-- CHECK: recDiffB: False
-- CHECK: recDiffBoth: False
-- CHECK: recFF_FF: True

import Html exposing (text)


type alias Pair =
    { a : Bool, b : Bool }


main =
    let
        ref : Pair
        ref = { a = True, b = False }

        sameAsRef : Pair
        sameAsRef = { a = True, b = False }

        flipA : Pair
        flipA = { a = False, b = False }

        flipB : Pair
        flipB = { a = True, b = True }

        flipBoth : Pair
        flipBoth = { a = False, b = True }

        bothFalse : Pair
        bothFalse = { a = False, b = False }

        _ = Debug.log "recEq" (ref == sameAsRef)
        _ = Debug.log "recDiffA" (ref == flipA)
        _ = Debug.log "recDiffB" (ref == flipB)
        _ = Debug.log "recDiffBoth" (ref == flipBoth)
        _ = Debug.log "recFF_FF" (bothFalse == { a = False, b = False })
    in
    text "done"
