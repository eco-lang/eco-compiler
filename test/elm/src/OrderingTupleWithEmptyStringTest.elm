module OrderingTupleWithEmptyStringTest exposing (main)

{-| `<`, `<=`, `>`, `>=` on tuples with `""` in a String field. Regression
guard for the `EmptyString` special-case in `compareUnboxableSlot`.
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
        e : ( Int, String )
        e = ( 0, "" )

        a : ( Int, String )
        a = ( 0, "a" )

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
