module FloatDivTest exposing (main)

{-| Test float division.
-}

-- CHECK: div1: 2.5
-- CHECK: div2: -2.5
-- CHECK: div3: -2.5
-- CHECK: div4: 2.5

import Html exposing (text)


main =
    let
        _ = Debug.log "div1" (10.0 / 4.0)
        _ = Debug.log "div2" (-10.0 / 4.0)
        _ = Debug.log "div3" (10.0 / -4.0)
        _ = Debug.log "div4" (-10.0 / -4.0)
    in
    text "done"
