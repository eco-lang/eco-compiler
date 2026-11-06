module IntDivByZeroTest exposing (main)

{-| Checks that integer division `//` by zero gives 0, for a positive and for a negative dividend.
-}

-- CHECK: divZero1: 0
-- CHECK: divZero2: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "divZero1" (10 // 0)
        _ = Debug.log "divZero2" (-5 // 0)
    in
    text "done"
