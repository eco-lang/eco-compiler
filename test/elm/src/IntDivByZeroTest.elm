module IntDivByZeroTest exposing (main)

{-| Test integer division by zero returns 0 (Elm semantics).
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
