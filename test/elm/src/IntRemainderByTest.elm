module IntRemainderByTest exposing (main)

{-| Test remainderBy with all sign combinations.
    remainderBy preserves the sign of the dividend (truncated division).
-}

-- CHECK: rem1: 3
-- CHECK: rem2: -3
-- CHECK: rem3: 3
-- CHECK: rem4: -3

import Html exposing (text)


main =
    let
        _ = Debug.log "rem1" (remainderBy 4 7)
        _ = Debug.log "rem2" (remainderBy 4 -7)
        _ = Debug.log "rem3" (remainderBy -4 7)
        _ = Debug.log "rem4" (remainderBy -4 -7)
    in
    text "done"
