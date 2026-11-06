module FloatMulTest exposing (main)

{-| Float multiplication gives the expected sign and value for positive, mixed-sign, two negative and zero operands.

Whole-number results print without a decimal point, so `10.0 * 3.0` prints as 30.

-}

-- CHECK: mul1: 30
-- CHECK: mul2: -15
-- CHECK: mul3: 6
-- CHECK: mul4: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "mul1" (10.0 * 3.0)
        _ = Debug.log "mul2" (5.0 * -3.0)
        _ = Debug.log "mul3" (-2.0 * -3.0)
        _ = Debug.log "mul4" (0.0 * 100.0)
    in
    text "done"
