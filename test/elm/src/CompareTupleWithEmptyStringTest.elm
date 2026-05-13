module CompareTupleWithEmptyStringTest exposing (main)

{-| `compare` on tuples whose String field can be `""`. This path IS
already special-cased in `compareUnboxableSlot` (Utils.cpp:181-194), so
these should pass today — regression guard against a fix that drops the
special case while addressing F2 generally.
-}

-- CHECK: ee: EQ
-- CHECK: ea: LT
-- CHECK: ae: GT
-- CHECK: f0_ea: LT
-- CHECK: f0_ae: GT

import Html exposing (text)


main =
    let
        _ = Debug.log "ee" (compare ( 0, "" ) ( 0, "" ))
        _ = Debug.log "ea" (compare ( 0, "" ) ( 0, "a" ))
        _ = Debug.log "ae" (compare ( 0, "a" ) ( 0, "" ))
        _ = Debug.log "f0_ea" (compare ( "", 0 ) ( "a", 0 ))
        _ = Debug.log "f0_ae" (compare ( "a", 0 ) ( "", 0 ))
    in
    text "done"
