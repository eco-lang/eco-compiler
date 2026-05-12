module CompareTupleWithEmptyListNestedTest exposing (main)

{-| F2 nested two tuple levels deep. The inner Tuple2 is itself a
heap object whose List Int field can hold Const_Nil; the outer Tuple2
field comparison routes into the inner Tuple2 → `compareUnboxableSlot`
on the List field — same bug surface.
-}

-- CHECK: ee: EQ
-- CHECK: eA: LT
-- CHECK: Ae: GT
-- CHECK: triple_eA: LT
-- CHECK: triple_Ae: GT

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        _ = Debug.log "ee" (compare ( ( 0, emptyL ), 1 ) ( ( 0, emptyL ), 1 ))
        _ = Debug.log "eA" (compare ( ( 0, emptyL ), 1 ) ( ( 0, [ 1 ] ), 1 ))
        _ = Debug.log "Ae" (compare ( ( 0, [ 1 ] ), 1 ) ( ( 0, emptyL ), 1 ))
        _ = Debug.log "triple_eA" (compare ( 0, emptyL, "x" ) ( 0, [ 1 ], "x" ))
        _ = Debug.log "triple_Ae" (compare ( 0, [ 1 ], "x" ) ( 0, emptyL, "x" ))
    in
    text "done"
