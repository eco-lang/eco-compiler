module NotEqualBoolRecordTest exposing (main)

{-| `/=` on records of type `{ flag : Bool }` gives the right answer for all
four combinations of a record holding `True` and one holding `False`.
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
