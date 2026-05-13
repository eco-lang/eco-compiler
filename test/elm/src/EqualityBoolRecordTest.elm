module EqualityBoolRecordTest exposing (main)

{-| Record equality with Bool fields. Per the invariants, Bool is *not*
unboxed in heap fields (only Int / Float / Char are), so each Bool field
is stored as an `!eco.value` HPointer constant. Recursive eq through
records walks these and trips the same nullptr-collapse path.
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
