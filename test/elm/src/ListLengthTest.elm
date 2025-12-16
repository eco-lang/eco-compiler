module ListLengthTest exposing (main)

{-| Test List.length.
-}

-- CHECK: len1: 0
-- CHECK: len2: 3
-- CHECK: len3: 5

import Html exposing (text)


main =
    let
        _ = Debug.log "len1" (List.length [])
        _ = Debug.log "len2" (List.length [1, 2, 3])
        _ = Debug.log "len3" (List.length [1, 2, 3, 4, 5])
    in
    text "done"
