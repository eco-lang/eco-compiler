module IntRemainderByTest exposing (main)

{-| Checks that `remainderBy` gives a result with the sign of the dividend, for all four sign combinations of divisor and dividend.

`remainderBy 4 -7` and `remainderBy -4 -7` are both -3, and the two positive
dividends give 3 whatever the divisor's sign: the result is that of truncated
division.

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
