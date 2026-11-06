module CompareTupleWithEmptyListNestedTest exposing (main)

{-| `compare` on tuples nested two deep whose `List Int` field may be empty.

A pair inside a pair, and a triple, are compared position by position; where
the earlier positions are equal, an empty list orders before `[ 1 ]` and equal
to another empty list.

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
