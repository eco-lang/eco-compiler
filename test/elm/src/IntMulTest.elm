module IntMulTest exposing (main)

{-| Checks integer multiplication `*` with positive, mixed-sign, two negative and zero operands.
-}

-- CHECK: mul1: 30
-- CHECK: mul2: -15
-- CHECK: mul3: 6
-- CHECK: mul4: 0

import Html exposing (text)


main =
    let
        _ = Debug.log "mul1" (10 * 3)
        _ = Debug.log "mul2" (5 * -3)
        _ = Debug.log "mul3" (-2 * -3)
        _ = Debug.log "mul4" (0 * 100)
    in
    text "done"
