module FloatAddTest exposing (main)

{-| Test float addition.
-}

-- CHECK: add1: 13
-- CHECK: add2: 0
-- CHECK: add3: -5

import Html exposing (text)


main =
    let
        _ = Debug.log "add1" (10.0 + 3.0)
        _ = Debug.log "add2" (5.0 + -5.0)
        _ = Debug.log "add3" (-2.0 + -3.0)
    in
    text "done"
