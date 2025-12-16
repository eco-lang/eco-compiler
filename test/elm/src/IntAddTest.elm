module IntAddTest exposing (main)

{-| Test integer addition.
-}

-- CHECK: add1: 13
-- CHECK: add2: 0
-- CHECK: add3: -5

import Html exposing (text)


main =
    let
        _ = Debug.log "add1" (10 + 3)
        _ = Debug.log "add2" (5 + -5)
        _ = Debug.log "add3" (-2 + -3)
    in
    text "done"
