module ComparableMinMaxTest exposing (main)

{-| Test min and max on Comparable types.
-}

-- CHECK: minStr: "apple"
-- CHECK: maxStr: "zebra"
-- CHECK: minChar: 'a'
-- CHECK: maxChar: 'z'

import Html exposing (text)


main =
    let
        _ = Debug.log "minStr" (min "apple" "zebra")
        _ = Debug.log "maxStr" (max "apple" "zebra")
        _ = Debug.log "minChar" (min 'a' 'z')
        _ = Debug.log "maxChar" (max 'a' 'z')
    in
    text "done"
