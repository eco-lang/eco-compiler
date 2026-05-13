module OrderingEmptyListTest exposing (main)

{-| `<`, `<=`, `>`, `>=` on List Int including `[]`. Each operator
routes through its own `Elm_Kernel_Utils_*` symbol.
-}

-- CHECK: lt_ee: False
-- CHECK: lt_ea: True
-- CHECK: lt_ae: False
-- CHECK: le_ee: True
-- CHECK: le_ea: True
-- CHECK: le_ae: False
-- CHECK: gt_ee: False
-- CHECK: gt_ea: False
-- CHECK: gt_ae: True
-- CHECK: ge_ee: True
-- CHECK: ge_ea: False
-- CHECK: ge_ae: True
-- CHECK: lt_ab: True
-- CHECK: ge_ab: False

import Html exposing (text)


main =
    let
        emptyL : List Int
        emptyL = []

        _ = Debug.log "lt_ee" (emptyL < emptyL)
        _ = Debug.log "lt_ea" (emptyL < [ 1 ])
        _ = Debug.log "lt_ae" ([ 1 ] < emptyL)
        _ = Debug.log "le_ee" (emptyL <= emptyL)
        _ = Debug.log "le_ea" (emptyL <= [ 1 ])
        _ = Debug.log "le_ae" ([ 1 ] <= emptyL)
        _ = Debug.log "gt_ee" (emptyL > emptyL)
        _ = Debug.log "gt_ea" (emptyL > [ 1 ])
        _ = Debug.log "gt_ae" ([ 1 ] > emptyL)
        _ = Debug.log "ge_ee" (emptyL >= emptyL)
        _ = Debug.log "ge_ea" (emptyL >= [ 1 ])
        _ = Debug.log "ge_ae" ([ 1 ] >= emptyL)
        _ = Debug.log "lt_ab" ([ 1 ] < [ 2 ])
        _ = Debug.log "ge_ab" ([ 1 ] >= [ 2 ])
    in
    text "done"
