module IntPowNegativeExponentTest exposing (main)

{-| Checks integer exponentiation `^` with a negative exponent: the truncation of the real result,
which is 1 for base 1, 1 or -1 for base -1 by the parity of the exponent, and 0 for every other base,
0 included (The Definition of Standard Elm, ruling A43).
-}

-- CHECK: one: 1
-- CHECK: minusOneOdd: -1
-- CHECK: minusOneEven: 1
-- CHECK: two: 0
-- CHECK: minusTwo: 0
-- CHECK: zero: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "one" (1 ^ -1)
        _ = Debug.log "minusOneOdd" ((-1) ^ -3)
        _ = Debug.log "minusOneEven" ((-1) ^ -2)
        _ = Debug.log "two" (2 ^ -1)
        _ = Debug.log "minusTwo" ((-2) ^ -1)
        _ = Debug.log "zero" (0 ^ -1)
    in
    text "done"
