module NotEqualBoolRecordTest exposing (main)

{-| `/=` on a record containing a Bool field. The record is heap, so
the field-level comparison takes the `resolveAndCompare` path that
handles const/const correctly today — regression guard.
-}

-- CHECK: tt: False
-- CHECK: tf: True
-- CHECK: ft: True
-- CHECK: ff: False

import Html exposing (text)


type alias Flag =
    { flag : Bool }


main =
    let
        rt : Flag
        rt = { flag = True }

        rf : Flag
        rf = { flag = False }

        _ = Debug.log "tt" (rt /= rt)
        _ = Debug.log "tf" (rt /= rf)
        _ = Debug.log "ft" (rf /= rt)
        _ = Debug.log "ff" (rf /= rf)
    in
    text "done"
