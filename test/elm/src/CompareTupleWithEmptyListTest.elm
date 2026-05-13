module CompareTupleWithEmptyListTest exposing (main)

{-| `compare` on tuples whose List field can be `[]` (Const_Nil).
This is the F2 bug: `compareUnboxableSlot` only special-cases
`Const_EmptyString` vs heap; Nil-vs-heap falls through to the raw
constant-byte comparison which produces the wrong sign (Nil=5, heap=0).
Expected to FAIL on `main` today.
-}

-- CHECK: ee: EQ
-- CHECK: eA: LT
-- CHECK: Ae: GT
-- CHECK: eAB: LT
-- CHECK: ABe: GT
-- CHECK: f0_ee: LT
-- CHECK: f0_Ae: GT

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        _ = Debug.log "ee" (compare ( 0, emptyL ) ( 0, emptyL ))
        _ = Debug.log "eA" (compare ( 0, emptyL ) ( 0, [ 1 ] ))
        _ = Debug.log "Ae" (compare ( 0, [ 1 ] ) ( 0, emptyL ))
        _ = Debug.log "eAB" (compare ( 0, emptyL ) ( 0, [ 1, 2 ] ))
        _ = Debug.log "ABe" (compare ( 0, [ 1, 2 ] ) ( 0, emptyL ))
        _ = Debug.log "f0_ee" (compare ( emptyL, 0 ) ( [ 1 ], 0 ))
        _ = Debug.log "f0_Ae" (compare ( [ 1 ], 0 ) ( emptyL, 0 ))
    in
    text "done"
