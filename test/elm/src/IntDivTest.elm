module IntDivTest exposing (main)

{-| Checks that integer division `//` truncates toward zero for all four sign combinations of dividend and divisor.

`10 // 3` and `-10 // -3` give 3; `-10 // 3` and `10 // -3` give -3, where
flooring division would give -4.

-}

-- CHECK: div1: 3
-- CHECK: div2: -3
-- CHECK: div3: -3
-- CHECK: div4: 3

import Html exposing (text)


main =
    let
        _ = Debug.log "div1" (10 // 3)
        _ = Debug.log "div2" (-10 // 3)
        _ = Debug.log "div3" (10 // -3)
        _ = Debug.log "div4" (-10 // -3)
    in
    text "done"
