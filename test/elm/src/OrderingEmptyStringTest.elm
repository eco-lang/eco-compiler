module OrderingEmptyStringTest exposing (main)

{-| `<`, `<=`, `>`, `>=` on String including `""`. Each operator
routes through its own `Elm_Kernel_Utils_*` symbol; all share the
`Export::toPtr` collapse but the current top-level early return in
`cmp` produces correct results. Regression guard.
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
        _ = Debug.log "lt_ee" ("" < "")
        _ = Debug.log "lt_ea" ("" < "a")
        _ = Debug.log "lt_ae" ("a" < "")
        _ = Debug.log "le_ee" ("" <= "")
        _ = Debug.log "le_ea" ("" <= "a")
        _ = Debug.log "le_ae" ("a" <= "")
        _ = Debug.log "gt_ee" ("" > "")
        _ = Debug.log "gt_ea" ("" > "a")
        _ = Debug.log "gt_ae" ("a" > "")
        _ = Debug.log "ge_ee" ("" >= "")
        _ = Debug.log "ge_ea" ("" >= "a")
        _ = Debug.log "ge_ae" ("a" >= "")
        _ = Debug.log "lt_ab" ("a" < "b")
        _ = Debug.log "ge_ab" ("a" >= "b")
    in
    text "done"
