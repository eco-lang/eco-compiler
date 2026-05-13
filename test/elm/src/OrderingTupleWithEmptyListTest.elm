module OrderingTupleWithEmptyListTest exposing (main)

{-| `<`, `<=`, `>`, `>=` on tuples with `[]` in a List Int field.
Same F2 bug surface as `CompareTupleWithEmptyListTest`, expressed via
the relational operators that route through their own kernel symbols.
-}

-- CHECK: lt_ee: False
-- CHECK: lt_eA: True
-- CHECK: lt_Ae: False
-- CHECK: le_ee: True
-- CHECK: le_eA: True
-- CHECK: le_Ae: False
-- CHECK: gt_ee: False
-- CHECK: gt_eA: False
-- CHECK: gt_Ae: True
-- CHECK: ge_ee: True
-- CHECK: ge_eA: False
-- CHECK: ge_Ae: True

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        e : ( Int, List Int )
        e = ( 0, emptyL )

        a : ( Int, List Int )
        a = ( 0, [ 1 ] )

        _ = Debug.log "lt_ee" (e < e)
        _ = Debug.log "lt_eA" (e < a)
        _ = Debug.log "lt_Ae" (a < e)
        _ = Debug.log "le_ee" (e <= e)
        _ = Debug.log "le_eA" (e <= a)
        _ = Debug.log "le_Ae" (a <= e)
        _ = Debug.log "gt_ee" (e > e)
        _ = Debug.log "gt_eA" (e > a)
        _ = Debug.log "gt_Ae" (a > e)
        _ = Debug.log "ge_ee" (e >= e)
        _ = Debug.log "ge_eA" (e >= a)
        _ = Debug.log "ge_Ae" (a >= e)
    in
    text "done"
